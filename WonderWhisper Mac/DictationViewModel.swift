import Foundation
import Combine
import Carbon.HIToolbox

@MainActor
final class DictationViewModel: ObservableObject {
    @Published var status: String = "Idle"
    @Published var isRecording: Bool = false
    @Published var audioLevel: Float = 0

    // Long-form prompt for LLM
    @Published var prompt: String = UserDefaults.standard.string(forKey: "llm.userPrompt") ?? AppConfig.defaultDictationPrompt

    // Transcription + LLM preferences
    @Published var transcriptionModel: String = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel { didSet { persistAndUpdate() } }
    @Published var llmEnabled: Bool = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true { didSet { persistAndUpdate() } }
    @Published var llmModel: String = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel { didSet { persistAndUpdate() } }

    // Vocabulary
    @Published var vocabCustom: String = UserDefaults.standard.string(forKey: "vocab.custom") ?? "" { didSet { persistAndUpdate() } }
    @Published var vocabSpelling: String = UserDefaults.standard.string(forKey: "vocab.spelling") ?? "" { didSet { persistAndUpdate() } }

    private let controller: DictationController
    private var timer: Timer?
    let history = HistoryStore()

    // Hotkey
    private let hotkeys = HotkeyManager()
    @Published var useFnGlobe: Bool = false { didSet { updateHotkeys() } }

    // Insertion
    @Published var useAXInsertion: Bool = UserDefaults.standard.object(forKey: "insertion.useAX") as? Bool ?? false { didSet { updateInsertion() } }

    init() {
        // Capture persisted settings locally to avoid referencing self before all properties are initialized
        let persistedTranscriptionModel = UserDefaults.standard.string(forKey: "transcription.model") ?? AppConfig.defaultTranscriptionModel
        let persistedLLMEnabled = UserDefaults.standard.object(forKey: "llm.enabled") as? Bool ?? true
        let persistedLLMModel = UserDefaults.standard.string(forKey: "llm.model") ?? AppConfig.defaultLLMModel
        let persistedVocabCustom = UserDefaults.standard.string(forKey: "vocab.custom") ?? ""
        let persistedVocabSpelling = UserDefaults.standard.string(forKey: "vocab.spelling") ?? ""
        let persistedUseAXInsertion = UserDefaults.standard.object(forKey: "insertion.useAX") as? Bool ?? false
        let persistedPrompt = UserDefaults.standard.string(forKey: "llm.userPrompt") ?? "Rewrite for clarity and professionalism; preserve meaning; fix obvious errors; keep user intent."

        let keychain = KeychainService()
        let http = GroqHTTPClient(apiKeyProvider: { keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) })

        var transcriber: TranscriptionProvider = GroqTranscriptionProvider(client: http)
        var transcriberSettings = TranscriptionSettings(
            endpoint: AppConfig.groqAudioTranscriptions,
            model: persistedTranscriptionModel,
            timeout: 180
        )
        if persistedTranscriptionModel.lowercased().contains("parakeet") || persistedTranscriptionModel.lowercased().contains("local") {
            transcriber = ParakeetTranscriptionProvider()
            // Dummy settings to satisfy interface (not used by local provider)
            transcriberSettings = TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: persistedTranscriptionModel)
        }

        let llm = GroqLLMProvider(client: http)
        // Build initial structured system prompt using the user-configured prompt as base
        let system = PromptBuilder.buildSystemMessage(base: persistedPrompt, customVocabulary: persistedVocabCustom, customSpelling: persistedVocabSpelling)
        let llmSettings = LLMSettings(
            endpoint: AppConfig.groqChatCompletions,
            model: persistedLLMModel,
            systemPrompt: system,
            timeout: 60
        )

        let recorder = AudioRecorder()
        let inserter = InsertionService()
        inserter.useAXInsertion = persistedUseAXInsertion
        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            transcriberSettings: transcriberSettings,
            llm: llm,
            llmSettings: llmSettings,
            inserter: inserter,
            history: history
        )
        // Now that self is fully initialized, hook up level monitoring
        recorder.onLevel = { [weak self] level in
            guard let self = self else { return }
            Task { @MainActor in self.audioLevel = level }
        }
        // Apply initial LLM enabled
        Task { await controller.updateLLMEnabled(persistedLLMEnabled) }

        // Default hotkey: ⌘⌥Space
        hotkeys.onActivate = { [weak self] in self?.toggle() }
        hotkeys.registeredShortcut = HotkeyManager.Shortcut(keyCode: UInt32(kVK_Space), modifiers: HotkeyManager.carbonModifiers(from: [.command, .option]))

        // Load saved settings
        let savedFn = UserDefaults.standard.bool(forKey: "useFnGlobe")
        self.useFnGlobe = savedFn
        updateHotkeys()
        updateProviders()

        // Poll state periodically for a simple UI reflection
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                let s = await self.controllerState()
                await MainActor.run {
                    if self.status != s { self.status = s }
                    let rec = (s == "Recording")
                    if self.isRecording != rec { self.isRecording = rec }
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func controllerState() async -> String {
        let s = await controller.currentState()
        switch s {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .processing: return "Processing"
        case .inserting: return "Inserting"
        case .error(let message): return "Error: \(message)"
        }
    }

    func toggle() {
        // Persist prompt whenever toggling, so changes aren't lost
        UserDefaults.standard.set(prompt, forKey: "llm.userPrompt")
        Task { await controller.toggle(userPrompt: prompt) }
    }

    func saveGroqApiKey(_ value: String) {
        let kc = KeychainService()
        do { try kc.setSecret(value, forKey: AppConfig.groqAPIKeyAlias) } catch { print("Keychain error: \(error)") }
    }

    func setDefaultShortcut() {
        hotkeys.registeredShortcut = HotkeyManager.Shortcut(keyCode: UInt32(kVK_Space), modifiers: HotkeyManager.carbonModifiers(from: [.command, .option]))
    }

    private func updateHotkeys() {
        UserDefaults.standard.set(useFnGlobe, forKey: "useFnGlobe")
        hotkeys.useFnGlobe = useFnGlobe
    }

    private func updateInsertion() {
        UserDefaults.standard.set(useAXInsertion, forKey: "insertion.useAX")
        // InsertionService instance is held inside controller; no direct setter. This flag will be refreshed on next controller creation.
    }

    private func persistAndUpdate() {
        UserDefaults.standard.set(transcriptionModel, forKey: "transcription.model")
        UserDefaults.standard.set(llmEnabled, forKey: "llm.enabled")
        UserDefaults.standard.set(llmModel, forKey: "llm.model")
        UserDefaults.standard.set(vocabCustom, forKey: "vocab.custom")
        UserDefaults.standard.set(vocabSpelling, forKey: "vocab.spelling")
        UserDefaults.standard.set(prompt, forKey: "llm.userPrompt")
        updateProviders()
    }

    private func updateProviders() {
        // Rebuild structured system prompt and update settings using current long-form prompt as base
        let system = PromptBuilder.buildSystemMessage(base: prompt, customVocabulary: vocabCustom, customSpelling: vocabSpelling)
        var provider: TranscriptionProvider? = nil
        var tSettings = TranscriptionSettings(endpoint: AppConfig.groqAudioTranscriptions, model: transcriptionModel, timeout: 180)
        if transcriptionModel.lowercased().contains("parakeet") || transcriptionModel.lowercased().contains("local") {
            provider = ParakeetTranscriptionProvider()
            tSettings = TranscriptionSettings(endpoint: URL(string: "https://localhost")!, model: transcriptionModel)
        } else {
            provider = GroqTranscriptionProvider(client: GroqHTTPClient(apiKeyProvider: { KeychainService().getSecret(forKey: AppConfig.groqAPIKeyAlias) }))
        }
        let lSettings = LLMSettings(endpoint: AppConfig.groqChatCompletions, model: llmModel, systemPrompt: system, timeout: 60)
        Task {
            if let p = provider { await controller.updateTranscriberProvider(p) }
            await controller.updateTranscriberSettings(tSettings)
            await controller.updateLLMSettings(lSettings)
            await controller.updateLLMEnabled(llmEnabled)
        }
    }

    // Reprocess a saved history entry with current settings
    func reprocessHistoryEntry(_ entry: HistoryEntry) async {
        await controller.reprocess(entry: entry, userPrompt: prompt)
    }
}
