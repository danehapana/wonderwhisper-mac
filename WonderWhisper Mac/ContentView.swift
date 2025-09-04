//
//  ContentView.swift
//  WonderWhisper Mac
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI

private enum SidebarItem: Hashable, Identifiable {
    case home
    case history
    case settingsGeneral
    case settingsModels
    case settingsPrompts
    case settingsShortcuts

    var id: String {
        switch self {
        case .home: return "home"
        case .history: return "history"
        case .settingsGeneral: return "settings.general"
        case .settingsModels: return "settings.models"
        case .settingsPrompts: return "settings.prompts"
        case .settingsShortcuts: return "settings.shortcuts"
        }
    }

    var title: String {
        switch self {
        case .home: return "Dictation"
        case .history: return "History"
        case .settingsGeneral: return "General"
        case .settingsModels: return "Models"
        case .settingsPrompts: return "Prompts"
        case .settingsShortcuts: return "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "mic"
        case .history: return "clock"
        case .settingsGeneral: return "gear"
        case .settingsModels: return "brain.head.profile"
        case .settingsPrompts: return "text.justify.left"
        case .settingsShortcuts: return "keyboard"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = DictationViewModel()
    @State private var selection: SidebarItem? = .home

    private let items: [SidebarItem] = [
        .home, .history, .settingsGeneral, .settingsModels, .settingsPrompts, .settingsShortcuts
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("WonderWhisper") {
                    ForEach([SidebarItem.home, SidebarItem.history], id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
                Section("Settings") {
                    ForEach([SidebarItem.settingsGeneral, SidebarItem.settingsModels, SidebarItem.settingsPrompts, SidebarItem.settingsShortcuts], id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("WonderWhisper")
        } detail: {
            switch selection ?? .home {
            case .home:
                BasicDictationView(vm: vm)
                    .navigationTitle("Dictation")
            case .history:
                HistoryView()
                    .environmentObject(vm.history)
                    .navigationTitle("History")
            case .settingsGeneral:
                SettingsGeneralView(vm: vm)
                    .navigationTitle("Settings · General")
            case .settingsModels:
                SettingsModelsView(vm: vm)
                    .navigationTitle("Settings · Models")
            case .settingsPrompts:
                SettingsPromptsView(vm: vm)
                    .navigationTitle("Settings · Prompts")
            case .settingsShortcuts:
                SettingsShortcutsView(vm: vm)
                    .navigationTitle("Settings · Shortcuts")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { if selection == nil { selection = .home } }
    }
}

private struct BasicDictationView: View {
    @ObservedObject var vm: DictationViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Status: \(vm.status)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Post-processing prompt", text: $vm.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3, reservesSpace: true)

            Button(action: { vm.toggle() }) {
                Text("Toggle Dictation")
            }
            .keyboardShortcut(.space, modifiers: [.command, .option])
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
