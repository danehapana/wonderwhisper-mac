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
    @State private var waveformOverlay: WaveformOverlayController? = nil
    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .onAppear {
                    if menuBar == nil { menuBar = MenuBarController(viewModel: vm) }
                    // Prefer a waveform overlay for clear visibility
                    if waveformOverlay == nil { waveformOverlay = WaveformOverlayController(viewModel: vm) }
                    // Keep the notch indicator optional; comment out if undesired
                    // if notchIndicator == nil { notchIndicator = NotchIndicatorController(viewModel: vm, side: .right) }
                }
        }
    }
}
