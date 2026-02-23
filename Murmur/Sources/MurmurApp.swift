import AppKit
import Carbon.HIToolbox
import AVFoundation

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var isRecording = false
    var recorder: SimpleRecorder?
    var hotKeyRef: EventHotKeyRef?
    var eventHandlerRef: EventHandlerRef?
    var flagsMonitor: Any?
    var cmdTapTimes: [Date] = []  // Track recent tap times
    var cmdWasDown = false
    var pendingTapAction: DispatchWorkItem?
    let tapWindow: TimeInterval = 0.4  // Window to count taps
    let tapDebounce: TimeInterval = 0.25  // Wait after last tap before triggering
    var pttMode = false  // true = started via double-tap Cmd (will auto-paste)
    var continuousMode = false  // true = VAD continuous mode active
    var continuousRecorder: SimpleRecorder?
    
    // Menu items that need updating
    var startStopMenuItem: NSMenuItem!
    var pttMenuItem: NSMenuItem!
    var vadMenuItem: NSMenuItem!
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance check
        let lockFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".murmur.lock")
        if FileManager.default.fileExists(atPath: lockFile.path),
           let pidString = try? String(contentsOf: lockFile, encoding: .utf8),
           let pid = Int32(pidString),
           kill(pid, 0) == 0 {
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: lockFile, atomically: true, encoding: .utf8)
        
        NSApp.setActivationPolicy(.accessory)
        
        // Log system info and permissions on launch
        Logger.shared.logSystemInfo()
        Logger.shared.logPermissions()
        
        // Check accessibility permissions (needed for hotkeys and auto-paste)
        checkAccessibilityPermissions()
        
        // Create status bar item with menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
            image?.isTemplate = true  // Automatically adapts to light/dark menu bar
            button.image = image
        }
        
        // Build the menu
        menu = NSMenu()
        
        // Start/Stop PTT
        pttMenuItem = NSMenuItem(title: "Start PTT", action: #selector(startPTTFromMenu), keyEquivalent: "")
        pttMenuItem.target = self
        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            pttMenuItem.image = micImage
        }
        menu.addItem(pttMenuItem)
        
        // Start/Stop VAD
        vadMenuItem = NSMenuItem(title: "Start VAD", action: #selector(startVADFromMenu), keyEquivalent: "")
        vadMenuItem.target = self
        if let waveImage = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil) {
            vadMenuItem.image = waveImage
        }
        menu.addItem(vadMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if let gearImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) {
            settingsItem.image = gearImage
        }
        menu.addItem(settingsItem)
        
        // Check Permissions
        let permissionsItem = NSMenuItem(title: "Check Permissions...", action: #selector(checkPermissions), keyEquivalent: "")
        permissionsItem.target = self
        if let shieldImage = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil) {
            permissionsItem.image = shieldImage
        }
        menu.addItem(permissionsItem)
        
        // SecondChair submenu
        if Settings.shared.isSecondChairConfigured {
            menu.addItem(NSMenuItem.separator())

            let scMenu = NSMenu()

            let key = Settings.shared.secondChairApiKey
            let masked = String(key.prefix(8)) + "..." + String(key.suffix(4))
            let keyLabel = NSMenuItem(title: "Key: \(masked)", action: nil, keyEquivalent: "")
            keyLabel.isEnabled = false
            scMenu.addItem(keyLabel)

            let copyItem = NSMenuItem(title: "Copy API Key", action: #selector(copyApiKey), keyEquivalent: "")
            copyItem.target = self
            scMenu.addItem(copyItem)

            let rotateItem = NSMenuItem(title: "Rotate API Key", action: #selector(rotateApiKey), keyEquivalent: "")
            rotateItem.target = self
            scMenu.addItem(rotateItem)

            let scMenuItem = NSMenuItem(title: "SecondChair", action: nil, keyEquivalent: "")
            if let linkImage = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil) {
                scMenuItem.image = linkImage
            }
            scMenuItem.submenu = scMenu
            menu.addItem(scMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Murmur", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        if let quitImage = NSImage(systemSymbolName: "power", accessibilityDescription: nil) {
            quitItem.image = quitImage
        }
        menu.addItem(quitItem)
        
        statusItem.menu = menu

        // Clean up any orphaned temp audio files from previous sessions
        cleanupOrphanedTempFiles()

        // Register modifier tap detection for PTT clipboard
        setupDoubleTapCmd()

        // Observe settings changes
        NotificationCenter.default.addObserver(self, selector: #selector(tapModifierSettingsChanged), name: .tapModifierChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(secondChairSettingsChanged), name: .secondChairChanged, object: nil)

        // Start SecondChair command polling if configured
        setupSecondChair()
    }
    
    func installHotKeyEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                appDelegate.toggleFileRecording()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }

    func registerHotKey(keyCode: Int, modifiers: UInt) {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4D555252) // "MURR"
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            Logger.shared.log("Failed to register hotkey: \(status)")
        }
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    @objc func hotKeySettingsChanged() {
        unregisterHotKey()
        let hotKey = Settings.shared.fileRecordingHotKey
        registerHotKey(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
    }

    @objc func tapModifierSettingsChanged() {
        cmdTapTimes.removeAll()
        pendingTapAction?.cancel()
        pendingTapAction = nil
        cmdWasDown = false
    }
    
    func setupDoubleTapCmd() {
        // Monitor modifier key changes globally
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }
    
    func handleFlagsChanged(_ event: NSEvent) {
        let targetFlag = Settings.shared.tapModifier.cocoaFlag
        let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let activeRelevant = event.modifierFlags.intersection(relevantFlags)

        // Only count when ONLY the target modifier is pressed (no other modifiers)
        let modCleanDown = activeRelevant == targetFlag

        // Detect release: was cleanly down, now target modifier is up
        if cmdWasDown && !event.modifierFlags.contains(targetFlag) {
            let now = Date()

            pendingTapAction?.cancel()

            cmdTapTimes.append(now)
            cmdTapTimes = cmdTapTimes.filter { now.timeIntervalSince($0) < tapWindow }

            // Schedule action after debounce delay (to allow more taps)
            let action = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let finalCount = self.cmdTapTimes.count
                self.cmdTapTimes.removeAll()

                if finalCount >= 3 && Settings.shared.tripleTapEnabled {
                    Logger.shared.log("Quadruple-tap \(Settings.shared.tapModifier.symbol) detected (\(finalCount) taps)")
                    self.toggleContinuousMode()
                } else if finalCount == 2 && Settings.shared.doubleTapEnabled {
                    Logger.shared.log("Double-tap \(Settings.shared.tapModifier.symbol) detected")
                    self.togglePTT()
                }
            }
            pendingTapAction = action
            DispatchQueue.main.asyncAfter(deadline: .now() + tapDebounce, execute: action)
        }

        cmdWasDown = modCleanDown
    }
    
    func toggleContinuousMode() {
        // Triple-tap Cmd = toggle continuous (VAD) mode
        if continuousMode {
            stopContinuousMode()
        } else {
            // Stop any manual recording first
            if isRecording {
                stopRecording()
            }
            startContinuousMode()
        }
    }
    
    func startContinuousMode() {
        continuousRecorder = SimpleRecorder()
        continuousRecorder?.startContinuousMode()
        continuousMode = true
        updateIcon()
        Logger.shared.log("Continuous mode started (triple-tap ⌘ to stop)")
    }
    
    func stopContinuousMode() {
        continuousRecorder?.stopContinuousMode()
        continuousRecorder = nil
        continuousMode = false
        updateIcon()
        Logger.shared.log("Continuous mode stopped")
    }
    
    func togglePTT() {
        // Double-tap Cmd = PTT with clipboard paste
        // Don't allow if continuous mode is active
        if continuousMode {
            return
        }
        if isRecording && pttMode {
            stopRecording()
            pttMode = false
        } else if !isRecording {
            pttMode = true
            startRecording(autoPaste: true)
        }
    }
    
    func toggleFileRecording() {
        // Cmd+Space = file recording toggle (no clipboard)
        if isRecording && !pttMode {
            stopRecording()
        } else if !isRecording {
            pttMode = false
            startRecording(autoPaste: false)
        }
    }
    
    @objc func toggleRecordingFromMenu() {
        // Menu click = toggle recording or continuous mode
        if continuousMode {
            stopContinuousMode()
        } else if isRecording {
            pttMode = false
            stopRecording()
        } else {
            pttMode = false
            startRecording(autoPaste: false)
        }
    }
    
    @objc func startPTTFromMenu() {
        if isRecording && pttMode {
            stopRecording()
            pttMode = false
        } else if !isRecording && !continuousMode {
            pttMode = true
            startRecording(autoPaste: true)
        }
    }
    
    @objc func startVADFromMenu() {
        toggleContinuousMode()
    }
    
    @objc func openSettings() {
        SettingsWindowController.show()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    func startRecording(autoPaste: Bool) {
        recorder = SimpleRecorder()
        recorder?.autoPaste = autoPaste

        // Wire chunk upload to SecondChair when recording was triggered by a command
        if let sessionId = activeSessionId {
            recorder?.onChunkTranscribed = { text, timestamp, sequenceNum in
                SecondChairClient.shared.uploadChunk(
                    sessionId: sessionId,
                    content: text,
                    sequenceNum: sequenceNum,
                    timestamp: timestamp
                )
            }
        }

        recorder?.start(fileMode: !autoPaste)
        isRecording = true
        updateIcon()
    }
    
    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        updateIcon()
    }
    
    @objc func openLogFile() {
        let logURL = Settings.shared.recordingsFolder.appendingPathComponent("murmur.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            let alert = NSAlert()
            alert.messageText = "No Log File"
            alert.informativeText = "No log file exists yet. Try recording something first."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    
    func updateIcon() {
        if let button = statusItem.button {
            if continuousMode {
                // VAD active - RED
                let image = createColoredIcon(color: .systemRed)
                button.image = image
            } else if isRecording && pttMode {
                // PTT active - BLUE
                let image = createColoredIcon(color: .systemBlue)
                button.image = image
            } else {
                let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
                image?.isTemplate = true
                button.image = image
            }
        }
        // Update PTT menu item
        if isRecording && pttMode {
            pttMenuItem?.title = "Stop PTT"
            pttMenuItem?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        } else {
            pttMenuItem?.title = "Start PTT"
            pttMenuItem?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        }
        // Update VAD menu item
        if continuousMode {
            vadMenuItem?.title = "Stop VAD"
            vadMenuItem?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        } else {
            vadMenuItem?.title = "Start VAD"
            vadMenuItem?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: nil)
        }
    }
    
    func createColoredIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Rounded square background with transparent color
            let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            color.withAlphaComponent(0.35).setFill()
            bgPath.fill()

            // Draw waveform symbol on top
            if let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                if let configured = waveform.withSymbolConfiguration(config) {
                    let iconSize = CGSize(width: 14, height: 14)
                    let iconRect = CGRect(
                        x: (rect.width - iconSize.width) / 2,
                        y: (rect.height - iconSize.height) / 2,
                        width: iconSize.width,
                        height: iconSize.height
                    )
                    NSColor.white.set()
                    configured.draw(in: iconRect)
                }
            }

            return true
        }
        image.isTemplate = false
        return image
    }
    
    private func cleanupOrphanedTempFiles() {
        let recordingsDir = Settings.shared.recordingsFolder
        guard let contents = try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil) else { return }

        var cleaned = 0
        for url in contents {
            if url.pathExtension == "wav" && url.lastPathComponent.contains(".temp.") {
                try? FileManager.default.removeItem(at: url)
                cleaned += 1
            }
            // Also check session subdirectories
            if url.hasDirectoryPath {
                if let subContents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for subURL in subContents {
                        if subURL.pathExtension == "wav" && subURL.lastPathComponent.contains(".temp.") {
                            try? FileManager.default.removeItem(at: subURL)
                            cleaned += 1
                        }
                    }
                }
            }
        }
        if cleaned > 0 {
            Logger.shared.log("Cleaned up \(cleaned) orphaned temp file(s)")
        }
    }

    // MARK: - SecondChair Menu Actions

    @objc func copyApiKey() {
        let key = Settings.shared.secondChairApiKey
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        Logger.shared.log("SecondChair: API key copied to clipboard")
    }

    @objc func rotateApiKey() {
        let alert = NSAlert()
        alert.messageText = "Rotate API Key?"
        alert.informativeText = "This will generate a new API key and invalidate the current one. The web app will need to be updated with the new key."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rotate")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            SecondChairClient.shared.rotateKey { newKey in
                if let newKey = newKey {
                    let masked = String(newKey.prefix(8)) + "..." + String(newKey.suffix(4))
                    let successAlert = NSAlert()
                    successAlert.messageText = "API Key Rotated"
                    successAlert.informativeText = "New key: \(masked)\n\nThe key has been copied to your clipboard."
                    successAlert.alertStyle = .informational
                    successAlert.runModal()

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(newKey, forType: .string)
                } else {
                    let failAlert = NSAlert()
                    failAlert.messageText = "Rotation Failed"
                    failAlert.informativeText = "Could not rotate the API key. Check your connection and try again."
                    failAlert.alertStyle = .critical
                    failAlert.runModal()
                }
            }
        }
    }

    // MARK: - SecondChair Integration

    var activeSessionId: String?  // Set when recording was triggered by SecondChair

    func setupSecondChair() {
        let client = SecondChairClient.shared

        client.onStartRecording = { [weak self] sessionId, title, meetingLink in
            guard let self = self else { return }
            Logger.shared.log("SecondChair: Start recording — session: \(sessionId ?? "none"), title: \(title ?? "none")")

            self.activeSessionId = sessionId

            // Start file recording (same as menu Start Recording)
            if !self.isRecording && !self.continuousMode {
                self.pttMode = false
                self.startRecording(autoPaste: false)
            }
        }

        client.onStopRecording = { [weak self] in
            guard let self = self else { return }
            Logger.shared.log("SecondChair: Stop recording")

            if self.continuousMode {
                self.stopContinuousMode()
            } else if self.isRecording {
                self.pttMode = false
                self.stopRecording()
            }
            self.activeSessionId = nil
        }

        client.startPolling()
    }

    @objc func secondChairSettingsChanged() {
        SecondChairClient.shared.restartIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if continuousMode {
            stopContinuousMode()
        }
        if isRecording {
            stopRecording()
        }
        unregisterHotKey()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        let lockFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".murmur.lock")
        try? FileManager.default.removeItem(at: lockFile)
    }
    
    // MARK: - Accessibility Permissions
    
    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        
        if !trusted {
            // Show a more helpful alert after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showAccessibilityAlert()
            }
        }
    }
    
    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Murmur needs Accessibility permission to:
        • Use keyboard shortcuts (⌘ Space, ⌘⌘)
        • Auto-paste transcriptions
        
        Please grant access in System Settings → Privacy & Security → Accessibility, then restart Murmur.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
    
    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func checkPermissions() {
        PermissionsWindowController.show()
    }
}
