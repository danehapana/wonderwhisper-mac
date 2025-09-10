import Foundation
import OSLog

enum AppLog {
    static let dictation = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Dictation")
    static let network = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Network")
    static let insertion = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Insertion")
    static let ocr = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "OCR")
    static let hotkeys = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Hotkeys")
}
