import SwiftUI
import ApplicationServices

struct SettingsShortcutsView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var showAXInfo: Bool = false

    var body: some View {
        Form {
            Section("Global Shortcut") {
                Picker("Shortcut", selection: $vm.hotkeySelection) {
                    ForEach(HotkeyManager.Selection.allCases, id: \.self) { sel in
                        Text(sel.displayName).tag(sel)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: vm.hotkeySelection) { _, newValue in
                    showAXInfo = newValue.requiresAX && !Self.isAXTrusted()
                }
                if showAXInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This shortcut requires Accessibility permission (for modifier/Fn detection).")
                            .font(.caption)
                        HStack(spacing: 8) {
                            Button("Open Accessibility Settings") { Self.openAXSettings() }
                            Text("System Settings → Privacy & Security → Accessibility")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Section("Paste Last Transcript") {
                VStack(alignment: .leading, spacing: 8) {
                    ShortcutRecorderView(shortcut: $vm.pasteShortcut)
                    Text("Default: ⌃⌘V. Pastes last output (LLM preferred).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { showAXInfo = vm.hotkeySelection.requiresAX && !Self.isAXTrusted() }
    }

    private static func isAXTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
