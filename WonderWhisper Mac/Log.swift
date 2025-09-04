import Foundation
import OSLog

enum AppLog {
    static let dictation = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Dictation")
    static let network = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Network")
    static let insertion = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Insertion")
}

