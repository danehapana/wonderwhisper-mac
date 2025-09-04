import SwiftUI
import ApplicationServices

struct SettingsShortcutsView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var showAXInfo: Bool = false

    var body: some View {
        Form {
            Section("Fn/Globe") {
                Toggle("Use Fn/Globe key to toggle dictation", isOn: $vm.useFnGlobe)
                    .onChange(of: vm.useFnGlobe) { oldValue, newValue in
                        showAXInfo = newValue && !Self.isAXTrusted()
                    }
                if showAXInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility permission required for Fn/Globe detection.")
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
            Section("Standard Shortcut") {
                HStack(spacing: 12) {
                    Text("Default: ⌘⌥Space")
                    Button("Use Default") { vm.setDefaultShortcut() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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

