import Foundation
import AppKit
import AVFoundation
import CoreAudio
import Carbon.HIToolbox

// MARK: - Keyboard Shortcut Types

struct HotKeyCombination: Equatable {
    var keyCode: Int
    var modifiers: UInt

    static let defaultFileRecording = HotKeyCombination(keyCode: Int(kVK_Space), modifiers: UInt(cmdKey))

    var badges: [String] {
        var result: [String] = []
        if modifiers & UInt(controlKey) != 0 { result.append("⌃") }
        if modifiers & UInt(optionKey) != 0 { result.append("⌥") }
        if modifiers & UInt(shiftKey) != 0 { result.append("⇧") }
        if modifiers & UInt(cmdKey) != 0 { result.append("⌘") }
        result.append(Self.keyCodeNames[keyCode] ?? "Key \(keyCode)")
        return result
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var mods: UInt = 0
        if flags.contains(.command) { mods |= UInt(cmdKey) }
        if flags.contains(.option) { mods |= UInt(optionKey) }
        if flags.contains(.control) { mods |= UInt(controlKey) }
        if flags.contains(.shift) { mods |= UInt(shiftKey) }
        return mods
    }

    static let keyCodeNames: [Int: String] = [
        Int(kVK_Space): "Space",
        Int(kVK_Return): "Return",
        Int(kVK_Tab): "Tab",
        Int(kVK_Delete): "Delete",
        Int(kVK_Escape): "Esc",
        Int(kVK_ANSI_A): "A", Int(kVK_ANSI_B): "B", Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_D): "D", Int(kVK_ANSI_E): "E", Int(kVK_ANSI_F): "F",
        Int(kVK_ANSI_G): "G", Int(kVK_ANSI_H): "H", Int(kVK_ANSI_I): "I",
        Int(kVK_ANSI_J): "J", Int(kVK_ANSI_K): "K", Int(kVK_ANSI_L): "L",
        Int(kVK_ANSI_M): "M", Int(kVK_ANSI_N): "N", Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_P): "P", Int(kVK_ANSI_Q): "Q", Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_S): "S", Int(kVK_ANSI_T): "T", Int(kVK_ANSI_U): "U",
        Int(kVK_ANSI_V): "V", Int(kVK_ANSI_W): "W", Int(kVK_ANSI_X): "X",
        Int(kVK_ANSI_Y): "Y", Int(kVK_ANSI_Z): "Z",
        Int(kVK_ANSI_0): "0", Int(kVK_ANSI_1): "1", Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3", Int(kVK_ANSI_4): "4", Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6", Int(kVK_ANSI_7): "7", Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9",
        Int(kVK_F1): "F1", Int(kVK_F2): "F2", Int(kVK_F3): "F3",
        Int(kVK_F4): "F4", Int(kVK_F5): "F5", Int(kVK_F6): "F6",
        Int(kVK_F7): "F7", Int(kVK_F8): "F8", Int(kVK_F9): "F9",
        Int(kVK_F10): "F10", Int(kVK_F11): "F11", Int(kVK_F12): "F12",
        Int(kVK_UpArrow): "↑", Int(kVK_DownArrow): "↓",
        Int(kVK_LeftArrow): "←", Int(kVK_RightArrow): "→",
        Int(kVK_ANSI_Minus): "-", Int(kVK_ANSI_Equal): "=",
        Int(kVK_ANSI_LeftBracket): "[", Int(kVK_ANSI_RightBracket): "]",
        Int(kVK_ANSI_Backslash): "\\", Int(kVK_ANSI_Semicolon): ";",
        Int(kVK_ANSI_Quote): "'", Int(kVK_ANSI_Comma): ",",
        Int(kVK_ANSI_Period): ".", Int(kVK_ANSI_Slash): "/",
        Int(kVK_ANSI_Grave): "`",
    ]
}

enum TapModifier: String, CaseIterable {
    case command
    case option
    case control

    var displayName: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    var cocoaFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        }
    }
}

extension Notification.Name {
    static let fileRecordingHotKeyChanged = Notification.Name("fileRecordingHotKeyChanged")
    static let tapModifierChanged = Notification.Name("tapModifierChanged")
}

class Settings: ObservableObject {
    static let shared = Settings()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let recordingsFolder = "recordingsFolder"
        static let launchAtLogin = "launchAtLogin"
        static let silenceThreshold = "silenceThreshold"
        static let inputDeviceUID = "inputDeviceUID"
        static let outputDeviceUID = "outputDeviceUID"
        static let enterTriggerWord = "enterTriggerWord"
        static let enterTriggerEnabled = "enterTriggerEnabled"
        static let fileRecordingKeyCode = "fileRecordingKeyCode"
        static let fileRecordingModifiers = "fileRecordingModifiers"
        static let tapModifierKey = "tapModifierKey"
        static let doubleTapEnabled = "doubleTapEnabled"
        static let tripleTapEnabled = "tripleTapEnabled"
    }
    
    var recordingsFolder: URL {
        get {
            if let path = defaults.string(forKey: Keys.recordingsFolder) {
                return URL(fileURLWithPath: path)
            }
            // Default to ~/Documents/Murmur
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Murmur")
            return defaultDir
        }
        set {
            defaults.set(newValue.path, forKey: Keys.recordingsFolder)
            objectWillChange.send()
        }
    }
    
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            objectWillChange.send()
        }
    }
    
    var silenceThreshold: Double {
        get {
            let value = defaults.double(forKey: Keys.silenceThreshold)
            return value > 0 ? value : 3.0  // Default 3 seconds
        }
        set {
            defaults.set(newValue, forKey: Keys.silenceThreshold)
            objectWillChange.send()
            Logger.shared.log("Silence threshold changed to: \(newValue)s")
        }
    }
    
    var inputDeviceUID: String? {
        get { defaults.string(forKey: Keys.inputDeviceUID) }
        set {
            defaults.set(newValue, forKey: Keys.inputDeviceUID)
            objectWillChange.send()
            if let uid = newValue {
                Logger.shared.log("Input device changed to: \(uid)")
            }
        }
    }
    
    var outputDeviceUID: String? {
        get { defaults.string(forKey: Keys.outputDeviceUID) }
        set {
            defaults.set(newValue, forKey: Keys.outputDeviceUID)
            objectWillChange.send()
            if let uid = newValue {
                Logger.shared.log("Output device changed to: \(uid)")
            }
        }
    }
    
    var enterTriggerWord: String {
        get { defaults.string(forKey: Keys.enterTriggerWord) ?? "vortex" }
        set {
            defaults.set(newValue, forKey: Keys.enterTriggerWord)
            objectWillChange.send()
        }
    }
    
    var enterTriggerEnabled: Bool {
        get { defaults.bool(forKey: Keys.enterTriggerEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.enterTriggerEnabled)
            objectWillChange.send()
        }
    }

    var fileRecordingHotKey: HotKeyCombination {
        get {
            let keyCode = defaults.object(forKey: Keys.fileRecordingKeyCode) as? Int ?? Int(kVK_Space)
            let modifiers = defaults.object(forKey: Keys.fileRecordingModifiers) as? Int ?? Int(cmdKey)
            return HotKeyCombination(keyCode: keyCode, modifiers: UInt(modifiers))
        }
        set {
            defaults.set(newValue.keyCode, forKey: Keys.fileRecordingKeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Keys.fileRecordingModifiers)
            objectWillChange.send()
            NotificationCenter.default.post(name: .fileRecordingHotKeyChanged, object: nil)
        }
    }

    var tapModifier: TapModifier {
        get {
            let raw = defaults.string(forKey: Keys.tapModifierKey) ?? "command"
            return TapModifier(rawValue: raw) ?? .command
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.tapModifierKey)
            objectWillChange.send()
            NotificationCenter.default.post(name: .tapModifierChanged, object: nil)
        }
    }

    var doubleTapEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.doubleTapEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.doubleTapEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.doubleTapEnabled)
            objectWillChange.send()
        }
    }

    var tripleTapEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.tripleTapEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.tripleTapEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.tripleTapEnabled)
            objectWillChange.send()
        }
    }

    private init() {}
}

// MARK: - Audio Device Helper

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let displayName: String  // Unique name for UI (may include index)
    let isInput: Bool
    let isOutput: Bool
}

class AudioDeviceManager {
    static let shared = AudioDeviceManager()
    
    func getInputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.isInput }
    }
    
    func getOutputDevices() -> [AudioDevice] {
        return getAllDevices().filter { $0.isOutput }
    }
    
    func getAllDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        
        guard status == noErr else { return [] }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        
        guard status == noErr else { return [] }
        
        // First pass: collect all devices
        var devices: [AudioDevice] = []
        var nameCounts: [String: Int] = [:]
        
        for deviceID in deviceIDs {
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID) else { continue }
            
            let isInput = hasInputStream(deviceID)
            let isOutput = hasOutputStream(deviceID)
            
            guard isInput || isOutput else { continue }
            
            // Track how many times we've seen this name
            let count = nameCounts[name, default: 0] + 1
            nameCounts[name] = count
            
            // Create display name with index if duplicate
            let displayName = count > 1 ? "\(name) (\(count))" : name
            
            devices.append(AudioDevice(id: deviceID, uid: uid, name: name, displayName: displayName, isInput: isInput, isOutput: isOutput))
        }
        
        // Second pass: update first occurrence if there are duplicates
        for i in 0..<devices.count {
            let name = devices[i].name
            if nameCounts[name, default: 0] > 1 && devices[i].displayName == name {
                devices[i] = AudioDevice(
                    id: devices[i].id,
                    uid: devices[i].uid,
                    name: devices[i].name,
                    displayName: "\(name) (1)",
                    isInput: devices[i].isInput,
                    isOutput: devices[i].isOutput
                )
            }
        }
        
        return devices
    }
    
    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        return status == noErr ? name as String : nil
    }
    
    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        return status == noErr ? uid as String : nil
    }
    
    private func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        
        // Device has input if it has any input streams
        return status == noErr && dataSize > 0
    }
    
    private func hasOutputStream(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        
        // Device has output if it has any output streams
        return status == noErr && dataSize > 0
    }
    
    func setDefaultInputDevice(uid: String) {
        guard let device = getAllDevices().first(where: { $0.uid == uid }) else { return }
        
        var deviceID = device.id
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
    }
    
    func setDefaultOutputDevice(uid: String) {
        guard let device = getAllDevices().first(where: { $0.uid == uid }) else { return }
        
        var deviceID = device.id
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
    }
}

// MARK: - Shortcut Recorder View

class ShortcutRecorderView: NSView {
    var hotKey: HotKeyCombination
    var onHotKeyChanged: ((HotKeyCombination) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private var actionButton: NSButton!
    private var promptLabel: NSTextField?
    private var pulseTimer: Timer?

    init(frame: NSRect, hotKey: HotKeyCombination) {
        self.hotKey = hotKey
        super.init(frame: frame)
        rebuildIdleState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(hotKey: HotKeyCombination) {
        self.hotKey = hotKey
        if !isRecording {
            rebuildIdleState()
        }
    }

    private func clearSubviews() {
        subviews.forEach { $0.removeFromSuperview() }
        promptLabel = nil
    }

    private func rebuildIdleState() {
        clearSubviews()
        stopPulse()

        wantsLayer = true
        layer?.borderWidth = 0
        layer?.borderColor = nil

        var x: CGFloat = 0
        for badge in hotKey.badges {
            let keyView = makeKeyBadge(key: badge)
            keyView.frame.origin = NSPoint(x: x, y: (bounds.height - 26) / 2)
            addSubview(keyView)
            x += keyView.frame.width + 6
        }

        actionButton = NSButton(title: "Edit", target: self, action: #selector(editTapped))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        actionButton.sizeToFit()
        actionButton.frame.origin = NSPoint(x: x + 8, y: (bounds.height - actionButton.frame.height) / 2)
        addSubview(actionButton)
    }

    private func enterRecordingState() {
        clearSubviews()
        isRecording = true

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor

        promptLabel = NSTextField(labelWithString: "Press shortcut...")
        promptLabel!.frame = NSRect(x: 10, y: (bounds.height - 20) / 2, width: bounds.width - 90, height: 20)
        promptLabel!.font = NSFont.systemFont(ofSize: 13)
        promptLabel!.textColor = .secondaryLabelColor
        addSubview(promptLabel!)

        actionButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        actionButton.sizeToFit()
        actionButton.frame.origin = NSPoint(x: bounds.width - actionButton.frame.width - 4, y: (bounds.height - actionButton.frame.height) / 2)
        addSubview(actionButton)

        startPulse()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil
        }
    }

    private func exitRecordingState() {
        isRecording = false
        stopPulse()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        rebuildIdleState()
    }

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape {
            exitRecordingState()
            return
        }

        let mods = HotKeyCombination.carbonModifiers(from: event.modifierFlags)

        if mods == 0 {
            NSSound.beep()
            return
        }

        let candidate = HotKeyCombination(keyCode: keyCode, modifiers: mods)

        if !testHotKeyAvailability(candidate) {
            let alert = NSAlert()
            alert.messageText = "Shortcut Conflict"
            alert.informativeText = "The shortcut \(candidate.badges.joined(separator: " ")) is already in use by another application."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        hotKey = candidate
        exitRecordingState()
        onHotKeyChanged?(candidate)
    }

    private func testHotKeyAvailability(_ combo: HotKeyCombination) -> Bool {
        var testRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x54455354) // "TEST"
        hotKeyID.id = 999

        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            UInt32(combo.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &testRef
        )

        if status == noErr, let ref = testRef {
            UnregisterEventHotKey(ref)
            return true
        }
        return false
    }

    private func startPulse() {
        var on = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.layer?.borderColor = on ?
                NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor :
                NSColor.controlAccentColor.cgColor
            on.toggle()
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    @objc private func editTapped() {
        enterRecordingState()
    }

    @objc private func cancelTapped() {
        exitRecordingState()
    }

    private func makeKeyBadge(key: String) -> NSView {
        let width: CGFloat = key.count > 1 ? 60 : 36
        let badge = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.separatorColor.cgColor

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = badge.bounds
        gradientLayer.cornerRadius = 6
        gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0.1).cgColor,
            NSColor.clear.cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.5)
        badge.layer?.addSublayer(gradientLayer)

        let label = NSTextField(labelWithString: key)
        label.frame = NSRect(x: 0, y: 3, width: width, height: 20)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        badge.addSubview(label)

        return badge
    }
}

// MARK: - Modern Settings Window

class SettingsWindowController: NSWindowController {
    static var shared: SettingsWindowController?
    private var folderPathField: NSTextField?
    private var silenceValueLabel: NSTextField?
    private var triggerWordField: NSTextField?
    private var shortcutRecorder: ShortcutRecorderView?
    private var tapModifierPopup: NSPopUpButton?
    private var doubleTapCheckbox: NSButton?
    private var tripleTapCheckbox: NSButton?
    private var doubleTapBadgesContainer: NSView?
    private var tripleTapBadgesContainer: NSView?

    private let windowWidth: CGFloat = 420
    private let windowHeight: CGFloat = 896
    private let cardPadding: CGFloat = 16
    private let cardSpacing: CGFloat = 12
    private let innerPadding: CGFloat = 14

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 896),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur Settings"
        window.center()
        
        // Modern vibrant background
        let visualEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .sidebar
        visualEffect.state = .active
        window.contentView = visualEffect
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let window = window, let container = window.contentView else { return }
        
        var yOffset: CGFloat = windowHeight - 24
        
        // ════════════════════════════════════════════════════════════
        // HEADER
        // ════════════════════════════════════════════════════════════
        let headerView = createHeader()
        headerView.frame.origin = NSPoint(x: cardPadding, y: yOffset - 70)
        container.addSubview(headerView)
        yOffset -= 90
        
        // ════════════════════════════════════════════════════════════
        // RECORDINGS CARD
        // ════════════════════════════════════════════════════════════
        let recordingsCard = createCard(width: windowWidth - cardPadding * 2, height: 120)
        recordingsCard.frame.origin = NSPoint(x: cardPadding, y: yOffset - 120)
        
        let recordingsContent = createRecordingsSection()
        recordingsContent.frame.origin = NSPoint(x: innerPadding, y: innerPadding)
        recordingsCard.addSubview(recordingsContent)
        
        container.addSubview(recordingsCard)
        yOffset -= 132
        
        // ════════════════════════════════════════════════════════════
        // KEYBOARD SHORTCUTS CARD
        // ════════════════════════════════════════════════════════════
        let shortcutsCard = createCard(width: windowWidth - cardPadding * 2, height: 310)
        shortcutsCard.frame.origin = NSPoint(x: cardPadding, y: yOffset - 310)

        let shortcutsContent = createShortcutsSection()
        shortcutsContent.frame.origin = NSPoint(x: innerPadding, y: innerPadding)
        shortcutsCard.addSubview(shortcutsContent)

        container.addSubview(shortcutsCard)
        yOffset -= 322
        
        // ════════════════════════════════════════════════════════════
        // AUDIO DEVICES CARD
        // ════════════════════════════════════════════════════════════
        let audioCard = createCard(width: windowWidth - cardPadding * 2, height: 130)
        audioCard.frame.origin = NSPoint(x: cardPadding, y: yOffset - 130)
        
        let audioContent = createAudioDevicesSection()
        audioContent.frame.origin = NSPoint(x: innerPadding, y: innerPadding)
        audioCard.addSubview(audioContent)
        
        container.addSubview(audioCard)
        yOffset -= 142
        
        // ════════════════════════════════════════════════════════════
        // CONTINUOUS MODE CARD
        // ════════════════════════════════════════════════════════════
        let continuousCard = createCard(width: windowWidth - cardPadding * 2, height: 125)
        continuousCard.frame.origin = NSPoint(x: cardPadding, y: yOffset - 125)
        
        let continuousContent = createContinuousModeSection()
        continuousContent.frame.origin = NSPoint(x: innerPadding, y: innerPadding)
        continuousCard.addSubview(continuousContent)
        
        container.addSubview(continuousCard)
        yOffset -= 137
        
    }
    
    // MARK: - Header
    
    private func createHeader() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth - cardPadding * 2, height: 80))
        
        // App icon - matching About dialog style
        let iconSize: CGFloat = 64
        let iconView = NSView(frame: NSRect(x: 0, y: 8, width: iconSize, height: iconSize))
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 14
        iconView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        
        let iconImage = NSImageView(frame: NSRect(x: 14, y: 14, width: 36, height: 36))
        if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
            iconImage.image = img.withSymbolConfiguration(config)
            iconImage.contentTintColor = .white
        }
        iconView.addSubview(iconImage)
        container.addSubview(iconView)
        
        // App name
        let appName = NSTextField(labelWithString: "Murmur")
        appName.frame = NSRect(x: iconSize + 16, y: 44, width: 200, height: 28)
        appName.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        appName.textColor = .labelColor
        container.addSubview(appName)
        
        // Tagline
        let tagline = NSTextField(labelWithString: "Voice recording with AI transcription")
        tagline.frame = NSRect(x: iconSize + 16, y: 28, width: 300, height: 20)
        tagline.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        tagline.textColor = .secondaryLabelColor
        container.addSubview(tagline)

        // Version + Debug Log button
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: "v\(version) (\(build))")
        versionLabel.frame = NSRect(x: iconSize + 16, y: 10, width: 80, height: 16)
        versionLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        container.addSubview(versionLabel)

        let logBtn = NSButton(title: "Debug Log", target: self, action: #selector(openDebugLog))
        logBtn.bezelStyle = .rounded
        logBtn.controlSize = .mini
        logBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        logBtn.sizeToFit()
        logBtn.frame.origin = NSPoint(x: iconSize + 16 + 80 + 4, y: 8)
        container.addSubview(logBtn)

        return container
    }
    
    // MARK: - Card Container
    
    private func createCard(width: CGFloat, height: CGFloat) -> NSView {
        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.wantsLayer = true
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        
        return card
    }
    
    // MARK: - Section Header
    
    private func createSectionTitle(title: String, icon: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        
        let iconView = NSImageView(frame: NSRect(x: 0, y: 2, width: 20, height: 20))
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = img
            iconView.contentTintColor = .controlAccentColor
        }
        container.addSubview(iconView)
        
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 26, y: 0, width: 200, height: 24)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        container.addSubview(label)
        
        return container
    }
    
    // MARK: - Recordings Section
    
    private func createRecordingsSection() -> NSView {
        let width = windowWidth - cardPadding * 2 - innerPadding * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 95))
        
        var y: CGFloat = 72
        
        // Section title
        let title = createSectionTitle(title: "Recordings", icon: "folder.fill")
        title.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(title)
        y -= 36
        
        // Folder path display
        let folderContainer = NSView(frame: NSRect(x: 0, y: y, width: width, height: 32))
        folderContainer.wantsLayer = true
        folderContainer.layer?.cornerRadius = 6
        folderContainer.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        
        let folderIcon = NSImageView(frame: NSRect(x: 10, y: 6, width: 20, height: 20))
        if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            folderIcon.image = img
            folderIcon.contentTintColor = .secondaryLabelColor
        }
        folderContainer.addSubview(folderIcon)
        
        let folderPath = NSTextField(labelWithString: shortenPath(Settings.shared.recordingsFolder.path))
        folderPath.frame = NSRect(x: 36, y: 6, width: width - 120, height: 20)
        folderPath.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        folderPath.textColor = .secondaryLabelColor
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.tag = 100
        self.folderPathField = folderPath
        folderContainer.addSubview(folderPath)
        
        container.addSubview(folderContainer)
        y -= 44
        
        // Buttons row
        let browseBtn = createPillButton(title: "Change", action: #selector(browseFolder))
        browseBtn.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(browseBtn)
        
        let openBtn = createPillButton(title: "Open in Finder", action: #selector(openRecordingsFolder))
        openBtn.frame.origin = NSPoint(x: browseBtn.frame.width + 10, y: y)
        container.addSubview(openBtn)
        
        return container
    }
    
    // MARK: - Shortcuts Section
    
    private func createShortcutsSection() -> NSView {
        let width = windowWidth - cardPadding * 2 - innerPadding * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 285))

        var y: CGFloat = 262

        // Section title + Reset button
        let title = createSectionTitle(title: "Keyboard Shortcuts", icon: "keyboard")
        title.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(title)

        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetShortcutsToDefaults))
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small
        resetBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        resetBtn.sizeToFit()
        resetBtn.frame.origin = NSPoint(x: width - resetBtn.frame.width, y: y)
        container.addSubview(resetBtn)
        y -= 32

        // "File Recording" label
        let fileLabel = NSTextField(labelWithString: "File Recording")
        fileLabel.frame = NSRect(x: 0, y: y, width: 200, height: 16)
        fileLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fileLabel.textColor = .labelColor
        container.addSubview(fileLabel)
        y -= 26

        // ShortcutRecorderView + description
        let recorder = ShortcutRecorderView(
            frame: NSRect(x: 0, y: y, width: 200, height: 32),
            hotKey: Settings.shared.fileRecordingHotKey
        )
        recorder.onHotKeyChanged = { newHotKey in
            Settings.shared.fileRecordingHotKey = newHotKey
        }
        shortcutRecorder = recorder
        container.addSubview(recorder)

        let fileDesc = NSTextField(labelWithString: "Start/stop recording to file")
        fileDesc.frame = NSRect(x: 210, y: y + 6, width: width - 210, height: 20)
        fileDesc.font = NSFont.systemFont(ofSize: 12)
        fileDesc.textColor = .secondaryLabelColor
        container.addSubview(fileDesc)
        y -= 40

        // "Modifier Tap" label
        let tapLabel = NSTextField(labelWithString: "Modifier Tap")
        tapLabel.frame = NSRect(x: 0, y: y, width: 200, height: 16)
        tapLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        tapLabel.textColor = .labelColor
        container.addSubview(tapLabel)
        y -= 28

        // Tap key dropdown
        let tapKeyLabel = NSTextField(labelWithString: "Tap key:")
        tapKeyLabel.frame = NSRect(x: 0, y: y + 2, width: 60, height: 20)
        tapKeyLabel.font = NSFont.systemFont(ofSize: 12)
        tapKeyLabel.textColor = .labelColor
        container.addSubview(tapKeyLabel)

        let (tapContainer, popup) = createStyledPopup(frame: NSRect(x: 65, y: y - 2, width: 150, height: 28))
        for mod in TapModifier.allCases {
            popup.addItem(withTitle: "\(mod.displayName) (\(mod.symbol))")
            popup.menu?.items.last?.representedObject = mod.rawValue
        }
        let currentMod = Settings.shared.tapModifier
        for (index, item) in popup.menu!.items.enumerated() {
            if (item.representedObject as? String) == currentMod.rawValue {
                popup.selectItem(at: index)
                break
            }
        }
        popup.target = self
        popup.action = #selector(tapModifierChanged(_:))
        tapModifierPopup = popup
        container.addSubview(tapContainer)
        y -= 34

        // Double-tap checkbox
        let dblCheckbox = NSButton(checkboxWithTitle: "Double-tap", target: self, action: #selector(doubleTapToggled(_:)))
        dblCheckbox.frame = NSRect(x: 0, y: y, width: 100, height: 20)
        dblCheckbox.state = Settings.shared.doubleTapEnabled ? .on : .off
        dblCheckbox.font = NSFont.systemFont(ofSize: 12)
        doubleTapCheckbox = dblCheckbox
        container.addSubview(dblCheckbox)

        let dblDesc = NSTextField(labelWithString: "Record & paste transcription")
        dblDesc.frame = NSRect(x: 105, y: y, width: width - 105, height: 20)
        dblDesc.font = NSFont.systemFont(ofSize: 12)
        dblDesc.textColor = .secondaryLabelColor
        container.addSubview(dblDesc)
        y -= 28

        // Double-tap badges
        let dblBadges = NSView(frame: NSRect(x: 20, y: y, width: 200, height: 26))
        doubleTapBadgesContainer = dblBadges
        buildTapBadges(container: dblBadges, count: 2)
        container.addSubview(dblBadges)
        y -= 32

        // Triple-tap checkbox
        let tplCheckbox = NSButton(checkboxWithTitle: "Quadruple-tap", target: self, action: #selector(tripleTapToggled(_:)))
        tplCheckbox.frame = NSRect(x: 0, y: y, width: 100, height: 20)
        tplCheckbox.state = Settings.shared.tripleTapEnabled ? .on : .off
        tplCheckbox.font = NSFont.systemFont(ofSize: 12)
        tripleTapCheckbox = tplCheckbox
        container.addSubview(tplCheckbox)

        let tplDesc = NSTextField(labelWithString: "Toggle continuous mode (VAD)")
        tplDesc.frame = NSRect(x: 105, y: y, width: width - 105, height: 20)
        tplDesc.font = NSFont.systemFont(ofSize: 12)
        tplDesc.textColor = .secondaryLabelColor
        container.addSubview(tplDesc)
        y -= 28

        // Triple-tap badges
        let tplBadges = NSView(frame: NSRect(x: 20, y: y, width: 200, height: 26))
        tripleTapBadgesContainer = tplBadges
        buildTapBadges(container: tplBadges, count: 4)
        container.addSubview(tplBadges)

        return container
    }

    private func buildTapBadges(container: NSView, count: Int) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let symbol = Settings.shared.tapModifier.symbol
        var x: CGFloat = 0
        for _ in 0..<count {
            let badge = createKeyBadge(key: symbol)
            badge.frame.origin = NSPoint(x: x, y: 0)
            container.addSubview(badge)
            x += badge.frame.width + 6
        }
    }

    @objc private func tapModifierChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mod = TapModifier(rawValue: raw) else { return }
        Settings.shared.tapModifier = mod
        if let dbl = doubleTapBadgesContainer {
            buildTapBadges(container: dbl, count: 2)
        }
        if let tpl = tripleTapBadgesContainer {
            buildTapBadges(container: tpl, count: 4)
        }
    }

    @objc private func doubleTapToggled(_ sender: NSButton) {
        Settings.shared.doubleTapEnabled = sender.state == .on
    }

    @objc private func tripleTapToggled(_ sender: NSButton) {
        Settings.shared.tripleTapEnabled = sender.state == .on
    }

    @objc private func resetShortcutsToDefaults() {
        Settings.shared.fileRecordingHotKey = .defaultFileRecording
        Settings.shared.tapModifier = .command
        Settings.shared.doubleTapEnabled = true
        Settings.shared.tripleTapEnabled = true

        shortcutRecorder?.update(hotKey: .defaultFileRecording)
        doubleTapCheckbox?.state = .on
        tripleTapCheckbox?.state = .on

        if let popup = tapModifierPopup {
            for (index, item) in popup.menu!.items.enumerated() {
                if (item.representedObject as? String) == TapModifier.command.rawValue {
                    popup.selectItem(at: index)
                    break
                }
            }
        }

        if let dbl = doubleTapBadgesContainer {
            buildTapBadges(container: dbl, count: 2)
        }
        if let tpl = tripleTapBadgesContainer {
            buildTapBadges(container: tpl, count: 4)
        }
    }
    
    private func createKeyBadge(key: String) -> NSView {
        let width: CGFloat = key.count > 1 ? 60 : 36
        let badge = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.separatorColor.cgColor
        
        // Gradient effect for 3D look
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = badge.bounds
        gradientLayer.cornerRadius = 6
        gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0.1).cgColor,
            NSColor.clear.cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.5)
        badge.layer?.addSublayer(gradientLayer)
        
        let label = NSTextField(labelWithString: key)
        label.frame = NSRect(x: 0, y: 3, width: width, height: 20)
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        badge.addSubview(label)
        
        return badge
    }
    
    // MARK: - Continuous Mode Section
    
    private func createContinuousModeSection() -> NSView {
        let width = windowWidth - cardPadding * 2 - innerPadding * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        
        var y: CGFloat = 77
        
        // Section title
        let title = createSectionTitle(title: "Continuous Mode", icon: "waveform.circle")
        title.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(title)
        y -= 36
        
        // Silence threshold slider
        let sliderLabel = NSTextField(labelWithString: "Silence before transcribe:")
        sliderLabel.frame = NSRect(x: 0, y: y + 2, width: 150, height: 20)
        sliderLabel.font = NSFont.systemFont(ofSize: 13)
        sliderLabel.textColor = .labelColor
        container.addSubview(sliderLabel)
        
        let slider = NSSlider(value: Settings.shared.silenceThreshold, minValue: 1.0, maxValue: 5.0, target: self, action: #selector(silenceSliderChanged(_:)))
        slider.frame = NSRect(x: 155, y: y, width: width - 210, height: 24)
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = true
        container.addSubview(slider)
        
        silenceValueLabel = NSTextField(labelWithString: String(format: "%.1fs", Settings.shared.silenceThreshold))
        silenceValueLabel?.frame = NSRect(x: width - 45, y: y + 2, width: 45, height: 20)
        silenceValueLabel?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        silenceValueLabel?.textColor = .secondaryLabelColor
        silenceValueLabel?.alignment = .right
        container.addSubview(silenceValueLabel!)
        y -= 32
        
        // Enter trigger word
        let triggerCheckbox = NSButton(checkboxWithTitle: "Press Enter when I say:", target: self, action: #selector(triggerEnabledChanged(_:)))
        triggerCheckbox.frame = NSRect(x: 0, y: y, width: 165, height: 20)
        triggerCheckbox.state = Settings.shared.enterTriggerEnabled ? .on : .off
        triggerCheckbox.font = NSFont.systemFont(ofSize: 13)
        container.addSubview(triggerCheckbox)
        
        triggerWordField = NSTextField(string: Settings.shared.enterTriggerWord)
        triggerWordField?.frame = NSRect(x: 170, y: y - 2, width: width - 170, height: 24)
        triggerWordField?.font = NSFont.systemFont(ofSize: 13)
        triggerWordField?.placeholderString = "vortex"
        triggerWordField?.target = self
        triggerWordField?.action = #selector(triggerWordChanged(_:))
        triggerWordField?.isEnabled = Settings.shared.enterTriggerEnabled
        container.addSubview(triggerWordField!)
        
        return container
    }
    
    @objc private func silenceSliderChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        Settings.shared.silenceThreshold = value
        silenceValueLabel?.stringValue = String(format: "%.1fs", value)
    }
    
    @objc private func triggerEnabledChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        Settings.shared.enterTriggerEnabled = enabled
        triggerWordField?.isEnabled = enabled
    }
    
    @objc private func triggerWordChanged(_ sender: NSTextField) {
        Settings.shared.enterTriggerWord = sender.stringValue
    }
    
    // MARK: - Audio Devices Section
    
    private func createAudioDevicesSection() -> NSView {
        let width = windowWidth - cardPadding * 2 - innerPadding * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 105))
        
        var y: CGFloat = 82
        
        // Section title
        let title = createSectionTitle(title: "Audio Devices", icon: "speaker.wave.2.fill")
        title.frame.origin = NSPoint(x: 0, y: y)
        container.addSubview(title)
        y -= 36
        
        // Microphone dropdown
        let micLabel = NSTextField(labelWithString: "Microphone:")
        micLabel.frame = NSRect(x: 0, y: y + 2, width: 90, height: 20)
        micLabel.font = NSFont.systemFont(ofSize: 13)
        micLabel.textColor = .labelColor
        container.addSubview(micLabel)
        
        let (micContainer, micPopup) = createStyledPopup(frame: NSRect(x: 95, y: y - 2, width: width - 95, height: 28))
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "System Default")
        micPopup.menu?.items.first?.representedObject = nil

        let inputDevices = AudioDeviceManager.shared.getInputDevices()
        for device in inputDevices {
            micPopup.addItem(withTitle: device.displayName)
            micPopup.menu?.items.last?.representedObject = device.uid
        }

        if let currentUID = Settings.shared.inputDeviceUID {
            for (index, item) in micPopup.menu!.items.enumerated() {
                if (item.representedObject as? String) == currentUID {
                    micPopup.selectItem(at: index)
                    break
                }
            }
        }

        micPopup.target = self
        micPopup.action = #selector(inputDeviceChanged(_:))
        container.addSubview(micContainer)
        y -= 36
        
        // Speaker dropdown
        let speakerLabel = NSTextField(labelWithString: "Speaker:")
        speakerLabel.frame = NSRect(x: 0, y: y + 2, width: 90, height: 20)
        speakerLabel.font = NSFont.systemFont(ofSize: 13)
        speakerLabel.textColor = .labelColor
        container.addSubview(speakerLabel)
        
        let (speakerContainer, speakerPopup) = createStyledPopup(frame: NSRect(x: 95, y: y - 2, width: width - 95, height: 28))
        speakerPopup.removeAllItems()
        speakerPopup.addItem(withTitle: "System Default")
        speakerPopup.menu?.items.first?.representedObject = nil

        let outputDevices = AudioDeviceManager.shared.getOutputDevices()
        for device in outputDevices {
            speakerPopup.addItem(withTitle: device.displayName)
            speakerPopup.menu?.items.last?.representedObject = device.uid
        }

        if let currentUID = Settings.shared.outputDeviceUID {
            for (index, item) in speakerPopup.menu!.items.enumerated() {
                if (item.representedObject as? String) == currentUID {
                    speakerPopup.selectItem(at: index)
                    break
                }
            }
        }

        speakerPopup.target = self
        speakerPopup.action = #selector(outputDeviceChanged(_:))
        container.addSubview(speakerContainer)
        
        return container
    }
    
    @objc private func inputDeviceChanged(_ sender: NSPopUpButton) {
        let uid = sender.selectedItem?.representedObject as? String
        Settings.shared.inputDeviceUID = uid
        if let uid = uid {
            AudioDeviceManager.shared.setDefaultInputDevice(uid: uid)
        }
    }
    
    @objc private func outputDeviceChanged(_ sender: NSPopUpButton) {
        let uid = sender.selectedItem?.representedObject as? String
        Settings.shared.outputDeviceUID = uid
        if let uid = uid {
            AudioDeviceManager.shared.setDefaultOutputDevice(uid: uid)
        }
    }
    
    // MARK: - Helpers
    
    private func createStyledPopup(frame: NSRect) -> (container: NSView, popup: NSPopUpButton) {
        // Outer container with rounded pill shape
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = frame.height / 2
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        // Gradient for 3D depth (same style as key badges)
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        gradientLayer.cornerRadius = frame.height / 2
        gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.5)
        container.layer?.addSublayer(gradientLayer)

        // Popup button sits inside, borderless
        let popup = NSPopUpButton(frame: NSRect(x: 6, y: -1, width: frame.width - 12, height: frame.height + 2))
        popup.isBordered = false
        popup.font = NSFont.systemFont(ofSize: 13)
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        container.addSubview(popup)

        return (container, popup)
    }

    private func createPillButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.sizeToFit()
        button.frame.size.width += 16
        button.frame.size.height = 28
        return button
    }
    
    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
    
    // MARK: - Actions
    
    @objc private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.recordingsFolder
        panel.prompt = "Select"
        panel.message = "Choose where to save your recordings"
        
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                Settings.shared.recordingsFolder = url
                self?.folderPathField?.stringValue = self?.shortenPath(url.path) ?? url.path
            }
        }
    }
    
    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(Settings.shared.recordingsFolder)
    }

    @objc private func openDebugLog() {
        let logURL = Settings.shared.recordingsFolder.appendingPathComponent("murmur.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            let alert = NSAlert()
            alert.messageText = "No Log File"
            alert.informativeText = "No log file exists yet. Try recording something first."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    static func show() {
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


// MARK: - Permissions Window

class PermissionsWindowController: NSWindowController {
    static var shared: PermissionsWindowController?
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions"
        window.center()
        
        let visualEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .sidebar
        visualEffect.state = .active
        window.contentView = visualEffect
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        guard let window = window, let container = window.contentView else { return }
        
        let windowWidth: CGFloat = 340
        var y: CGFloat = 370
        
        // Icon
        let iconSize: CGFloat = 56
        let iconView = NSView(frame: NSRect(x: (windowWidth - iconSize) / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 12
        iconView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        
        let iconImage = NSImageView(frame: NSRect(x: 12, y: 12, width: 32, height: 32))
        if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            iconImage.image = img.withSymbolConfiguration(config)
            iconImage.contentTintColor = .white
        }
        iconView.addSubview(iconImage)
        container.addSubview(iconView)
        y -= iconSize + 16
        
        // Title
        let title = NSTextField(labelWithString: "Permissions")
        title.frame = NSRect(x: 0, y: y - 24, width: windowWidth, height: 24)
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        container.addSubview(title)
        y -= 36
        
        // Check permissions
        let micStatus = getMicStatus()
        let screenStatus = CGPreflightScreenCaptureAccess()
        let accessibilityStatus = AXIsProcessTrusted()
        
        // Permission rows
        y = addPermissionRow(to: container, y: y, width: windowWidth,
                            icon: "mic.fill", title: "Microphone",
                            description: "Record your voice for transcription",
                            granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            status: micStatus)

        y = addPermissionRow(to: container, y: y, width: windowWidth,
                            icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                            description: "Capture system audio from meetings",
                            granted: screenStatus,
                            status: screenStatus ? "Granted" : "Required")

        y = addPermissionRow(to: container, y: y, width: windowWidth,
                            icon: "hand.raised.fill", title: "Accessibility",
                            description: "Global keyboard shortcuts and auto-paste",
                            granted: accessibilityStatus,
                            status: accessibilityStatus ? "Granted" : "Required")
        
        y -= 12
        
        // Button
        let allGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
                        screenStatus && accessibilityStatus
        
        let buttonTitle = allGranted ? "All Set!" : "Open System Settings"
        let button = NSButton(title: buttonTitle, target: self, action: #selector(openSettings))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: (windowWidth - 160) / 2, y: y - 28, width: 160, height: 28)
        button.isEnabled = !allGranted
        container.addSubview(button)
    }
    
    private func getMicStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }
    
    private func addPermissionRow(to container: NSView, y: CGFloat, width: CGFloat,
                                  icon: String, title: String, description: String,
                                  granted: Bool, status: String) -> CGFloat {
        let rowHeight: CGFloat = 60
        let padding: CGFloat = 24

        // Icon
        let iconView = NSImageView(frame: NSRect(x: padding, y: y - 30, width: 24, height: 24))
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = img
            iconView.contentTintColor = .secondaryLabelColor
        }
        container.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: padding + 34, y: y - 26, width: 140, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        container.addSubview(titleLabel)

        // Description
        let descLabel = NSTextField(labelWithString: description)
        descLabel.frame = NSRect(x: padding + 34, y: y - 44, width: 200, height: 16)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .tertiaryLabelColor
        container.addSubview(descLabel)

        // Status badge
        let badgeWidth: CGFloat = 80
        let badge = NSView(frame: NSRect(x: width - padding - badgeWidth, y: y - 30, width: badgeWidth, height: 24))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = granted ?
            NSColor.systemGreen.withAlphaComponent(0.15).cgColor :
            NSColor.systemOrange.withAlphaComponent(0.15).cgColor

        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.frame = NSRect(x: 0, y: 3, width: badgeWidth, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = granted ? .systemGreen : .systemOrange
        statusLabel.alignment = .center
        badge.addSubview(statusLabel)
        container.addSubview(badge)

        return y - rowHeight
    }
    
    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func show() {
        shared = PermissionsWindowController()
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

