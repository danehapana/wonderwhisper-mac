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
                let url = try recorder.startRecording()
                currentRecordingURL = url
                state = .recording
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
        let maybeURL = recorder.stopRecording()
        guard let fileURL = maybeURL else { state = .error("No recording file"); return }

        do {
            let overallStart = Date()
            AppLog.dictation.log("Transcription start")
            state = .transcribing
            let t0 = Date()
            let transcript = try await transcriber.transcribe(fileURL: fileURL, settings: transcriberSettings)
            let transcribeDT = Date().timeIntervalSince(t0)
            AppLog.dictation.log("Transcription done in \(transcribeDT, format: .fixed(precision: 3))s")

            var output = transcript
            var llmDT: TimeInterval = 0
            let selected = screenContext.selectedText()
            var screenText: String? = nil
            if llmEnabled {
                state = .processing
                let (appName, _) = screenContext.frontmostAppNameAndBundle()
                screenText = await screenContext.captureActiveWindowText()
                let userMsg = PromptBuilder.buildUserMessage(transcription: transcript, selectedText: selected, appName: appName, screenContents: screenText)
                AppLog.dictation.log("LLM processing start")
                let t1 = Date()
                output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
                llmDT = Date().timeIntervalSince(t1)
                AppLog.dictation.log("LLM processing done in \(llmDT, format: .fixed(precision: 3))s")
            }

            state = .inserting
            inserter.insert(output)
            state = .idle

            // Record history entry
            let (appName, bundleID) = screenContext.frontmostAppNameAndBundle()
            let totalDT = Date().timeIntervalSince(overallStart)
            await history?.append(
                fileURL: currentRecordingURL,
                appName: appName,
                bundleID: bundleID,
                transcript: transcript,
                output: output,
                screenContext: screenText,
                selectedText: selected,
                transcriptionModel: transcriberSettings.model,
                llmModel: llmEnabled ? llmSettings.model : nil,
                transcriptionSeconds: transcribeDT,
                llmSeconds: llmEnabled ? llmDT : nil,
                totalSeconds: totalDT
            )
        } catch {
            AppLog.dictation.error("Pipeline error: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }

    func currentState() -> State { state }

    func updateTranscriberSettings(_ s: TranscriptionSettings) { self.transcriberSettings = s }
    func updateLLMSettings(_ s: LLMSettings) { self.llmSettings = s }
    func updateLLMEnabled(_ enabled: Bool) { self.llmEnabled = enabled }

    func reprocess(entry: HistoryEntry, userPrompt: String) async {
        guard let history = history, let url = await history.audioURL(for: entry) else { return }
        do {
            state = .transcribing
            let overallStart = Date()
            let t0 = Date()
            let transcript = try await transcriber.transcribe(fileURL: url, settings: transcriberSettings)
            let transcribeDT = Date().timeIntervalSince(t0)
            var output = transcript
            var llmDT: TimeInterval = 0
            let selected = screenContext.selectedText()
            var screenText: String? = nil
            if llmEnabled {
                state = .processing
                let (appName, _) = screenContext.frontmostAppNameAndBundle()
                screenText = await screenContext.captureActiveWindowText()
                let userMsg = PromptBuilder.buildUserMessage(transcription: transcript, selectedText: selected, appName: appName, screenContents: screenText)
                let t1 = Date()
                output = try await llm.process(text: userMsg, userPrompt: userPrompt, settings: llmSettings)
                llmDT = Date().timeIntervalSince(t1)
            }
            state = .idle
            var updated = entry
            updated.date = Date()
            updated.transcript = transcript
            updated.output = output
            updated.screenContext = screenText
            updated.selectedText = selected
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
