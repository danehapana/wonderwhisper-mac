//
//  WonderWhisper_MacApp.swift
//  WonderWhisper Mac
//
//  Created by Dane Kapoor on 4/9/25.
//

import SwiftUI
import AppKit

@main
struct WonderWhisper_MacApp: App {
    @StateObject private var vm = DictationViewModel()
    @State private var menuBar: MenuBarController? = nil
    @State private var notchIndicator: NotchIndicatorController? = nil
    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear {
                    if menuBar == nil { menuBar = MenuBarController(viewModel: vm) }
                    if notchIndicator == nil { notchIndicator = NotchIndicatorController(viewModel: vm, side: .right) }
                }
        }
    }
}
