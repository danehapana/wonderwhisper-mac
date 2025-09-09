import Foundation

actor DictationController {
    enum State: Equatable { case idle, recording, transcribing, processing, inserting, error(String) }
    private(set) var state: State = .idle

    private let recorder: AudioRecorder
    private var transcriber: TranscriptionProvider
    private var transcriberSettings: TranscriptionSettings
    private var llm: LLMProvider
    private var llmSettings: LLMSettings
    private let inserter: InsertionService
    private let screenContext: ScreenContextService
    private let history: HistoryStore?

    private var llmEnabled: Bool = true
    private var currentRecordingURL: URL?
    private var preCapturedScreenText: String?
    private var preCapturedScreenMethod: String?
    
    // Removed memory recording feature due to unreliable output

    init(recorder: AudioRecorder,
         transcriber: TranscriptionProvider,
         transcriberSettings: TranscriptionSettings,
         llm: LLMProvider,
         llmSettings: LLMSettings,
         inserter: InsertionService,
         screenContext: ScreenContextService = ScreenContextService(),
         history: HistoryStore? = nil) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.transcriberSettings = transcriberSettings
        self.llm = llm
        self.llmSettings = llmSettings
        self.inserter = inserter
        self.screenContext = screenContext
        self.history = history
    }

    func toggle(userPrompt: String) async {
        switch state {
        case .idle, .error:
            do {
                AppLog.dictation.log("Recording start")
                
                // Always use file-based recording (memory recording removed due to unreliable output)
                let url = try recorder.startRecording()
                currentRecordingURL = url
                
                // If AssemblyAI v3 streaming is active, begin live session and stream mic frames
                if let aai = transcriber as? AssemblyAIStreamingProvider {
                    try await aai.beginRealtimeSession(sampleRate: 16_000)
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await aai.feedPCM16(data) }
                    }
                } else if let dg = transcriber as? DeepgramStreamingProvider {
                    try await dg.beginRealtime()
                    try? recorder.startStreamingPCM16 { data in
                        Task { try? await dg.feedPCM16(data) }
                    }
                }
                state = .recording
                // Pre-capture screen context early (AX first, OCR fallback)
                preCapturedScreenText = nil
                if llmEnabled {
                    Task { await self.preCaptureScreenContext() }
                }
            } catch {
                AppLog.dictation.error("Recording start failed: \(error.localizedDescription)")
                state = .error("Recording start failed: \(error.localizedDescription)")
            }
        case .recording:
            await stopAndProcess(userPrompt: userPrompt)
        default:
            break
        }
    }

    private func stopAndProcess(userPrompt: String) async {
        guard state == .recording else { return }
        // Stop live streaming if active
        if transcriber is AssemblyAIStreamingProvider { recorder.stopStreamingPCM16() }
        if transcriber is DeepgramStreamingProvider { recorder.stopStreamingPCM16() }
        
        var recordingFileURL: URL? = nil // Track the file URL for history - defined at function scope
        
        do {
            let overallStart = Date()
            state = .transcribing
            let t0 = Date()
            var transcript: String = ""
            let hotkeySettings = TranscriptionSettings(endpoint: transcriberSettings.endpoint, model: transcriberSettings.model, timeout: transcriberSettings.timeout, context: "hotkey")
            
            // Handle streaming providers first
            if let aai = transcriber as? AssemblyAIStreamingProvider {
                // Prefer the live session's final transcript for speed
                transcript = try await aai.endRealtimeSessionAndGetTranscript()
                // If empty (fallback), run file-based for safety
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let maybeURL = await recorder.stopRecordingAndWait()
                    guard let fileURL = maybeURL else { throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"]) }
                    recordingFileURL = fileURL
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else if let dg = transcriber as? DeepgramStreamingProvider {
                // Prefer Deepgram live session transcript gathered during recording
                transcript = try await dg.endRealtime()
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let maybeURL = await recorder.stopRecordingAndWait()
                    guard let fileURL = maybeURL else { throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"]) }
                    recordingFileURL = fileURL
                    transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
                }
            } else {
                // Standard file-based transcription for non-streaming providers
                let maybeURL = await recorder.stopRecordingAndWait()
                guard let fileURL = maybeURL else { throw NSError(domain: "DictationController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recording file"]) }
                recordingFileURL = fileURL
                AppLog.dictation.log("Transcription start (file) provider=\(String(describing: type(of: self.transcriber))) file=\(fileURL.lastPathComponent)")
                transcript = try await transcriber.transcribe(fileURL: fileURL, settings: hotkeySettings)
            }
            let transcribeDT = Date().timeIntervalSince(t0)
            AppLog.dictation.log("Transcription done in \(transcribeDT, format: .fixed(precision: 3))s")

            var output = transcript
            var llmDT: TimeInterval = 0
            let selected = screenContext.selectedText()
            var screenText: String? = nil
            var screenMethod: String? = nil
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil
            if llmEnabled {
                state = .processing
                let (appName, _) = screenContext.frontmostAppNameAndBundle()
                // Prefer pre-captured context if available; else AX-first, then OCR
                if let pre = preCapturedScreenText, !pre.isEmpty {
                    screenText = pre
                    screenMethod = preCapturedScreenMethod
                } else if (selected?.isEmpty ?? true), let focused = screenContext.focusedText(), !focused.isEmpty {
                    screenText = focused
                    screenMethod = "AX"
                } else {
                    screenText = await screenContext.captureActiveWindowText()
                    screenMethod = (screenText?.isEmpty ?? true) ? nil : "OCR"
                }
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    appName: appName,
                    screenContents: screenText
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                AppLog.dictation.log("LLM processing start")
                let t1 = Date()
                do {
                    output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
                    llmDT = Date().timeIntervalSince(t1)
                    AppLog.dictation.log("LLM processing done in \(llmDT, format: .fixed(precision: 3))s")
                } catch {
                    let ns = error as NSError
                    AppLog.dictation.error("LLM error: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code)")
                    // Fallback to raw transcript on LLM failure
                    output = transcript
                    llmDT = 0
                    state = .transcribing
                }
            }

            // Apply deterministic text replacements on final output
            let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
            if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = TextReplacement.apply(to: output, withRules: rules)
            }
            // Ensure a single trailing space to facilitate continued dictation
            output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "

            state = .inserting
            inserter.insert(output)

            state = .idle

            // Record history entry
            let (appName, bundleID) = screenContext.frontmostAppNameAndBundle()
            let totalDT = Date().timeIntervalSince(overallStart)
            await history?.append(
                fileURL: recordingFileURL ?? currentRecordingURL,
                appName: appName,
                bundleID: bundleID,
                transcript: transcript,
                output: output,
                screenContext: screenText,
                screenContextMethod: screenMethod,
                selectedText: selected,
                llmSystemMessage: systemForHistory,
                llmUserMessage: userMsgForHistory,
                transcriptionModel: transcriberSettings.model,
                llmModel: llmEnabled ? llmSettings.model : nil,
                transcriptionSeconds: transcribeDT,
                llmSeconds: llmEnabled ? llmDT : nil,
                totalSeconds: totalDT
            )
        } catch {
            let ns = error as NSError
            AppLog.dictation.error("Pipeline error: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            // Persist audio so the user can reprocess later even on failure
            let (appName, bundleID) = screenContext.frontmostAppNameAndBundle()
            await history?.append(
                fileURL: recordingFileURL,
                appName: appName,
                bundleID: bundleID,
                transcript: "",
                output: "",
                screenContext: nil,
                screenContextMethod: nil,
                selectedText: screenContext.selectedText(),
                llmSystemMessage: llmEnabled ? llmSettings.systemPrompt : nil,
                llmUserMessage: nil,
                transcriptionModel: transcriberSettings.model,
                llmModel: llmEnabled ? llmSettings.model : nil,
                transcriptionSeconds: nil,
                llmSeconds: nil,
                totalSeconds: nil
            )
            state = .error(error.localizedDescription)
        }
        // Reset pre-captured context for the next run
        preCapturedScreenText = nil
        preCapturedScreenMethod = nil
    }

    func currentState() -> State { state }

    func updateTranscriberSettings(_ s: TranscriptionSettings) { self.transcriberSettings = s }
    func updateLLMSettings(_ s: LLMSettings) { self.llmSettings = s }
    func updateLLMEnabled(_ enabled: Bool) { self.llmEnabled = enabled }
    func updateTranscriberProvider(_ p: TranscriptionProvider) { self.transcriber = p }

    // Explicit controls for UI actions
    func finish(userPrompt: String) async {
        await stopAndProcess(userPrompt: userPrompt)
    }

    func cancel() async {
        guard state == .recording else { return }
        _ = recorder.stopRecording()
        if let url = currentRecordingURL { try? FileManager.default.removeItem(at: url) }
        currentRecordingURL = nil
        preCapturedScreenText = nil
        state = .idle
    }

    // Insert arbitrary text now (used by paste-last shortcut)
    func insert(_ text: String) {
        state = .inserting
        var output = text
        // Apply deterministic text replacements
        let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = TextReplacement.apply(to: output, withRules: rules)
        }
        // Only add a single trailing space; no other formatting
        output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        inserter.insert(output)
        state = .idle
    }

    func reprocess(entry: HistoryEntry, userPrompt: String) async {
        guard let history = history, let url = await history.audioURL(for: entry) else { return }
        do {
            state = .transcribing
            let overallStart = Date()
            let t0 = Date()
            let reprocSettings = TranscriptionSettings(endpoint: transcriberSettings.endpoint, model: transcriberSettings.model, timeout: transcriberSettings.timeout, context: "reprocess")
            let transcript = try await transcriber.transcribe(fileURL: url, settings: reprocSettings)
            let transcribeDT = Date().timeIntervalSince(t0)
            var output = transcript
            var llmDT: TimeInterval = 0
            var userMsgForHistory: String? = nil
            let systemForHistory = llmEnabled ? llmSettings.systemPrompt : nil

            let selected = screenContext.selectedText()
            var screenText: String? = nil
            var screenMethod: String? = nil
            if llmEnabled {
                state = .processing
                let (appName, _) = screenContext.frontmostAppNameAndBundle()
                // Prefer AX over OCR when no selection is present
                if (selected?.isEmpty ?? true), let focused = screenContext.focusedText(), !focused.isEmpty {
                    screenText = focused
                    screenMethod = "AX"
                } else {
                    screenText = await screenContext.captureActiveWindowText()
                    screenMethod = (screenText?.isEmpty ?? true) ? nil : "OCR"
                }
                let userMsg = PromptBuilder.buildUserMessage(
                    transcription: transcript,
                    selectedText: selected,
                    appName: appName,
                    screenContents: screenText
                )
                // Capture full user message for history
                userMsgForHistory = userMsg
                let t1 = Date()
                output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
                llmDT = Date().timeIntervalSince(t1)
            }
            state = .idle
            // Apply deterministic text replacements on final output
            let rules = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
            if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = TextReplacement.apply(to: output, withRules: rules)
            }
            // Ensure a single trailing space to facilitate continued dictation
            output = output.trimmingCharacters(in: .whitespacesAndNewlines) + " "
            var updated = entry
            updated.date = Date()
            updated.transcript = transcript
            updated.output = output
            updated.screenContext = screenText
            updated.selectedText = selected
            updated.screenContextMethod = screenMethod
            updated.llmSystemMessage = systemForHistory
            updated.llmUserMessage = userMsgForHistory
            updated.transcriptionModel = transcriberSettings.model
            updated.llmModel = llmEnabled ? llmSettings.model : nil
            updated.transcriptionSeconds = transcribeDT
            updated.llmSeconds = llmEnabled ? llmDT : nil
            updated.totalSeconds = Date().timeIntervalSince(overallStart)
            await history.replace(id: entry.id, with: updated)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Pre-capture helpers
extension DictationController {
    private func preCaptureScreenContext() async {
        // Try AX first as it's near-instant; fallback to OCR if needed
        if let focused = screenContext.focusedText(), !focused.isEmpty {
            self.preCapturedScreenText = focused
            self.preCapturedScreenMethod = "AX"
            return
        }
        let ocr = await screenContext.captureActiveWindowText()
        self.preCapturedScreenText = ocr
        self.preCapturedScreenMethod = (ocr?.isEmpty ?? true) ? nil : "OCR"
    }
}
