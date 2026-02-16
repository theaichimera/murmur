import Foundation
import AVFoundation
import AppKit

class Logger {
    static let shared = Logger()
    
    private var logURL: URL {
        Settings.shared.recordingsFolder.appendingPathComponent("murmur.log")
    }
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()
    
    private init() {
        // Ensure folder exists
        try? FileManager.default.createDirectory(
            at: Settings.shared.recordingsFolder,
            withIntermediateDirectories: true
        )
    }
    
    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        
        // Also log to console
        NSLog("[Murmur] %@", message)
        
        // Append to file
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
    
    func logPermissions() {
        log("=== PERMISSION CHECK ===")
        
        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            log("Microphone: ✅ AUTHORIZED")
        case .denied:
            log("Microphone: ❌ DENIED")
        case .restricted:
            log("Microphone: ❌ RESTRICTED")
        case .notDetermined:
            log("Microphone: ⚠️ NOT DETERMINED (will prompt)")
        @unknown default:
            log("Microphone: ❓ UNKNOWN")
        }
        
        // Screen Recording
        let screenAccess = CGPreflightScreenCaptureAccess()
        log("Screen Recording: \(screenAccess ? "✅ AUTHORIZED" : "❌ DENIED")")
        
        // Accessibility
        let accessibilityAccess = AXIsProcessTrusted()
        log("Accessibility: \(accessibilityAccess ? "✅ AUTHORIZED" : "❌ DENIED")")
        
        // Recordings folder
        let folder = Settings.shared.recordingsFolder
        let folderExists = FileManager.default.fileExists(atPath: folder.path)
        let isWritable = FileManager.default.isWritableFile(atPath: folder.path)
        log("Recordings folder: \(folder.path)")
        log("  Exists: \(folderExists ? "YES" : "NO")")
        log("  Writable: \(isWritable ? "YES" : "NO")")
        
        log("=== END PERMISSION CHECK ===")
    }
    
    func logSystemInfo() {
        log("=== SYSTEM INFO ===")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("App: \(Bundle.main.bundleIdentifier ?? "unknown")")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            log("Version: \(version)")
        }
        log("=== END SYSTEM INFO ===")
    }
    
    func clear() {
        try? FileManager.default.removeItem(at: logURL)
        log("Log file cleared")
    }
}
