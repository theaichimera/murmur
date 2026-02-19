import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit

class SimpleRecorder {
    private var systemCapture: SCStream?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var micURL: URL?
    private var startTime: Date?
    private var audioOutput: AudioOutput?
    private static var hasScreenPermission: Bool?
    
    // Mic recording with AVAudioEngine (pre-buffered for instant capture)
    private var audioEngine: AVAudioEngine?
    private var audioInputFile: AVAudioFile?
    
    // Pre-buffering for AVAudioEngine (captures audio before user presses record)
    // Uses a lock-free ring buffer to avoid blocking the audio hardware thread
    private var preBuffer: [AVAudioPCMBuffer?]  // Ring buffer (fixed size, no reallocation)
    private var preBufferWriteIndex: Int = 0     // Written by audio thread only
    private var preBufferCount: Int = 0          // Approximate count for pre-buffer reads
    private let preBufferLock = NSLock()          // Only used by NON-audio-thread reads
    private let preBufferDuration: TimeInterval = 2.0
    private var isPreBuffering = false
    private var isRecording = false
    private var preBufferFormat: AVAudioFormat?

    // I/O queue — all file writes happen here, never on the audio thread
    private let ioQueue = DispatchQueue(label: "com.murmur.audio-io", qos: .utility)
    
    // VAD (Voice Activity Detection) for continuous mode
    enum VADState { case idle, listening, speaking, silence }
    private var vadState: VADState = .idle
    private var isContinuousMode = false
    private var silenceStartTime: Date?
    private let speechThresholdRMS: Float = 0.01  // RMS level to detect speech
    private var continuousTimestamp: String?
    var onContinuousTranscript: ((String) -> Void)?  // Callback when continuous mode transcribes
    
    private var silenceThreshold: TimeInterval {
        return Settings.shared.silenceThreshold
    }
    
    var autoPaste = false  // If true, paste transcription to active window
    var onRecordingError: ((String) -> Void)?  // Callback for errors

    // Remember the frontmost app so we can restore focus before pasting
    private var savedFrontmostApp: NSRunningApplication?

    // Live chunked transcription (file recording mode only)
    private var sessionDir: URL?
    private var isFileRecordingMode = false
    private var micChunkFile: AVAudioFile?
    private var micChunkFrameCount: UInt32 = 0
    private var chunkIndex: Int = 0
    private let chunkDuration: TimeInterval = 15.0
    private var chunkWhisperPath: String?
    private var chunkModelPath: String?
    private var micOverlapBuffer: [AVAudioPCMBuffer] = []
    private let overlapDuration: TimeInterval = 5.0
    private var micChunkOverlapFrames: UInt32 = 0
    
    init() {
        // Initialize ring buffer with capacity for ~2s at 48kHz/4096 buffers
        preBuffer = [AVAudioPCMBuffer?](repeating: nil, count: 30)
        // Start pre-buffering immediately for instant recording
        startPreBuffering()
    }
    
    /// Start continuous audio capture for pre-buffering (captures before user presses record)
    private func startPreBuffering() {
        guard !isPreBuffering else { return }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            Logger.shared.log("Pre-buffer: No valid audio input")
            return
        }
        
        preBufferFormat = inputFormat
        let maxBufferCount = Int(preBufferDuration * inputFormat.sampleRate / 4096) + 1
        // Resize ring buffer to fit
        preBuffer = [AVAudioPCMBuffer?](repeating: nil, count: maxBufferCount)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Calculate RMS for VAD (lightweight — just reads float data)
            let rms = self.calculateRMS(buffer: buffer)

            // Make a copy of the buffer (unavoidable — buffer is reused by system)
            guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            bufferCopy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = bufferCopy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }

            // Handle continuous mode VAD (needs to run on audio thread for timing)
            if self.isContinuousMode {
                self.preBufferLock.lock()
                self.processVAD(rms: rms, buffer: bufferCopy)
                self.preBufferLock.unlock()
            } else if self.isRecording {
                // Dispatch ALL file I/O to the ioQueue — never block the audio thread
                self.ioQueue.async {
                    if let outputFile = self.audioInputFile {
                        try? outputFile.write(from: bufferCopy)
                    }
                    if self.isFileRecordingMode {
                        // Maintain overlap buffer
                        self.micOverlapBuffer.append(bufferCopy)
                        let sampleRate = self.preBufferFormat?.sampleRate ?? 48000
                        let maxOverlap = Int(self.overlapDuration * sampleRate / 4096) + 1
                        while self.micOverlapBuffer.count > maxOverlap {
                            self.micOverlapBuffer.removeFirst()
                        }
                        if let chunkFile = self.micChunkFile {
                            try? chunkFile.write(from: bufferCopy)
                            self.micChunkFrameCount += bufferCopy.frameLength
                            let newFrames = self.micChunkFrameCount - self.micChunkOverlapFrames
                            let elapsed = Double(newFrames) / sampleRate
                            if elapsed >= self.chunkDuration {
                                self.finishMicChunk()
                            }
                        }
                    }
                }
            } else {
                // Ring buffer write — no lock, no allocation, no array shift
                let idx = self.preBufferWriteIndex % self.preBuffer.count
                self.preBuffer[idx] = bufferCopy
                self.preBufferWriteIndex += 1
                self.preBufferCount = min(self.preBufferCount + 1, self.preBuffer.count)
            }
        }
        
        do {
            try engine.start()
            isPreBuffering = true
            Logger.shared.log("Pre-buffering started (keeping \(preBufferDuration)s of audio)")
        } catch {
            Logger.shared.log("Pre-buffer start error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - VAD (Voice Activity Detection) for Continuous Mode
    
    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frameLength))
    }
    
    private var lastVADLogTime: Date?
    
    private func processVAD(rms: Float, buffer: AVAudioPCMBuffer) {
        // Must be called with preBufferLock held
        let isSpeech = rms > speechThresholdRMS
        
        // Periodic debug logging (every 2 seconds)
        let now = Date()
        if lastVADLogTime == nil || now.timeIntervalSince(lastVADLogTime!) >= 2.0 {
            lastVADLogTime = now
            Logger.shared.log("VAD: state=\(vadState), rms=\(String(format: "%.4f", rms)), speech=\(isSpeech)")
        }
        
        switch vadState {
        case .idle:
            // Waiting to start - shouldn't happen in continuous mode
            break
            
        case .listening:
            if isSpeech {
                // Speech detected - start recording
                vadState = .speaking
                silenceStartTime = nil
                Logger.shared.log("VAD: Speech detected (rms=\(String(format: "%.4f", rms))), starting capture")
                startContinuousCapture()
            }
            // Keep pre-buffer updated while listening
            preBuffer.append(buffer)
            let maxBufferCount = Int(preBufferDuration * (preBufferFormat?.sampleRate ?? 48000) / 4096) + 1
            while preBuffer.count > maxBufferCount {
                preBuffer.removeFirst()
            }
            
        case .speaking:
            // Currently recording speech
            if let outputFile = audioInputFile {
                do {
                    try outputFile.write(from: buffer)
                } catch {
                    // Ignore write errors
                }
            }
            
            if !isSpeech {
                // Silence detected - start silence timer
                vadState = .silence
                silenceStartTime = Date()
                Logger.shared.log("VAD: Silence started, waiting \(silenceThreshold)s...")
            }
            
        case .silence:
            // In silence after speech - write buffer and check timeout
            if let outputFile = audioInputFile {
                do {
                    try outputFile.write(from: buffer)
                } catch {
                    // Ignore write errors
                }
            }
            
            if isSpeech {
                // Speech resumed - back to speaking
                vadState = .speaking
                silenceStartTime = nil
                Logger.shared.log("VAD: Speech resumed")
            } else if let startTime = silenceStartTime,
                      now.timeIntervalSince(startTime) >= silenceThreshold {
                // Silence threshold reached - transcribe
                Logger.shared.log("VAD: Silence threshold (\(silenceThreshold)s) reached, transcribing...")
                
                // Capture URLs before resetting state
                let capturedURL = micURL
                let capturedTimestamp = continuousTimestamp
                
                // Reset state BEFORE dispatching to avoid race conditions
                vadState = .listening
                silenceStartTime = nil
                audioInputFile = nil
                
                // Dispatch transcription with captured values
                if let url = capturedURL, let timestamp = capturedTimestamp {
                    DispatchQueue.global(qos: .utility).async {
                        self.processAndTranscribe(url: url, timestamp: timestamp)
                    }
                }
            }
        }
    }
    
    private func processAndTranscribe(url: URL, timestamp: String) {
        // Convert temp file to 16kHz WAV
        let tempURL = url.deletingPathExtension().appendingPathExtension("temp.wav")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            Logger.shared.log("VAD: Converting temp audio to 16kHz WAV...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", tempURL.path, url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: tempURL)
            Logger.shared.log("VAD: Conversion complete")
        } else {
            Logger.shared.log("VAD: No temp file found at \(tempURL.path)")
            return
        }
        
        // Transcribe
        Task {
            await self.transcribeContinuous(micURL: url, timestamp: timestamp)
        }
    }
    
    private func startContinuousCapture() {
        // Fixed filename, overwritten each segment, deleted after paste
        continuousTimestamp = "continuous"

        micURL = recordingsDir.appendingPathComponent("continuous_mic.wav")
        
        guard let format = preBufferFormat, let url = micURL else { return }
        
        let tempURL = url.deletingPathExtension().appendingPathExtension("temp.wav")
        
        do {
            audioInputFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            
            // Drain ring buffer
            var preBufferFrames: UInt32 = 0
            let count = min(preBufferCount, preBuffer.count)
            let startIdx = (preBufferWriteIndex - count + preBuffer.count) % preBuffer.count
            for i in 0..<count {
                let idx = (startIdx + i) % preBuffer.count
                if let buf = preBuffer[idx] {
                    try? audioInputFile?.write(from: buf)
                    preBufferFrames += buf.frameLength
                    preBuffer[idx] = nil
                }
            }
            preBufferCount = 0
            
            let preBufferSeconds = Double(preBufferFrames) / format.sampleRate
            Logger.shared.log("VAD: Wrote \(String(format: "%.2f", preBufferSeconds))s of pre-buffer")
        } catch {
            Logger.shared.log("VAD: Error creating audio file: \(error.localizedDescription)")
        }
    }
    
    private func transcribeContinuous(micURL: URL, timestamp: String) async {
        // Find whisper
        let bundledWhisper = Bundle.main.bundlePath + "/Contents/Frameworks/whisper/whisper-cli"
        let systemWhisper = "/opt/homebrew/bin/whisper-cli"
        let whisperPath = FileManager.default.fileExists(atPath: bundledWhisper) ? bundledWhisper : systemWhisper
        
        let bundledModel = Bundle.main.bundlePath + "/Contents/Resources/whisper/ggml-base.en.bin"
        let systemModel = "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin"
        let modelPath = FileManager.default.fileExists(atPath: bundledModel) ? bundledModel : systemModel
        
        guard FileManager.default.fileExists(atPath: whisperPath) else {
            Logger.shared.log("VAD: whisper-cli not found")
            return
        }
        
        let text = await transcribeAudio(url: micURL, whisperPath: whisperPath, modelPath: modelPath)
        var trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for enter trigger word
        var shouldPressEnter = false
        if Settings.shared.enterTriggerEnabled {
            // Normalize trigger: lowercase, remove punctuation, collapse spaces
            let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
            let triggerNormalized = Settings.shared.enterTriggerWord
                .lowercased()
                .components(separatedBy: punctuation).joined()
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            
            // Normalize transcription the same way for matching
            let textNormalized = trimmedText
                .lowercased()
                .components(separatedBy: punctuation).joined()
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            
            Logger.shared.log("VAD: Checking trigger word match")
            
            if textNormalized.hasSuffix(triggerNormalized) {
                // Find where to cut in original text - search backwards for trigger pattern
                let triggerWords = triggerNormalized.components(separatedBy: " ")
                let firstTriggerWord = triggerWords.first ?? triggerNormalized
                
                // Find the start of the trigger phrase in original text
                if let range = trimmedText.range(of: firstTriggerWord, options: [.backwards, .caseInsensitive]) {
                    trimmedText = String(trimmedText[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                shouldPressEnter = true
                Logger.shared.log("VAD: Trigger word detected! Will press Enter after paste")
            }
        }
        
        if !trimmedText.isEmpty {
            Logger.shared.log("VAD: Transcription complete (\(trimmedText.count) chars)")
            
            // Clean up audio file (continuous mode files are transient)
            try? FileManager.default.removeItem(at: micURL)

            // Paste to clipboard and simulate paste
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(trimmedText, forType: .string)
                
                self.onContinuousTranscript?(trimmedText)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.simulatePaste()

                    // Auto-submit after paste in continuous mode
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.simulateEnterKey()
                    }
                }
            }
        } else if shouldPressEnter {
            // Just trigger word with no other text - just press Enter
            Logger.shared.log("VAD: Only trigger word detected, pressing Enter")
            DispatchQueue.main.async {
                self.simulateEnterKey()
            }
        } else {
            Logger.shared.log("VAD: Empty transcription, skipping")
        }
    }
    
    // MARK: - Continuous Mode Public API
    
    func startContinuousMode() {
        Logger.shared.log("Starting continuous (VAD) mode...")
        
        if !isPreBuffering {
            startPreBuffering()
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        preBufferLock.lock()
        isContinuousMode = true
        vadState = .listening
        preBuffer.removeAll()
        preBufferLock.unlock()
        
        Logger.shared.log("Continuous mode active - listening for speech...")
    }
    
    func stopContinuousMode() {
        Logger.shared.log("Stopping continuous mode...")
        
        preBufferLock.lock()
        isContinuousMode = false
        vadState = .idle
        audioInputFile = nil
        preBufferLock.unlock()
        
        Logger.shared.log("Continuous mode stopped")
    }
    
    var isInContinuousMode: Bool {
        return isContinuousMode
    }
    
    // MARK: - Recordings Directory
    
    private var recordingsDir: URL {
        let dir = Settings.shared.recordingsFolder
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            Logger.shared.log("Recordings directory ready: \(dir.path)")
        } catch {
            Logger.shared.log("ERROR creating recordings directory: \(error.localizedDescription)")
        }
        return dir
    }
    
    func start(fileMode: Bool = true) {
        // Capture the frontmost app NOW so we can restore focus when pasting later
        savedFrontmostApp = NSWorkspace.shared.frontmostApplication

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)

        isFileRecordingMode = fileMode

        if fileMode {
            // Create per-session folder with chunks
            let sessionFolder = recordingsDir.appendingPathComponent(String(timestamp))
            try? FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
            let chunksFolder = sessionFolder.appendingPathComponent("chunks")
            try? FileManager.default.createDirectory(at: chunksFolder, withIntermediateDirectories: true)
            sessionDir = sessionFolder

            recordingURL = sessionFolder.appendingPathComponent("system.wav")
            micURL = sessionFolder.appendingPathComponent("mic.wav")

            resolveWhisperPaths()

            Logger.shared.log("Starting recording (file mode)...")
            Logger.shared.log("Session folder: \(sessionFolder.path)")
        } else {
            // PTT mode: fixed filenames, overwritten each time, deleted after paste
            recordingURL = recordingsDir.appendingPathComponent("ptt_system.wav")
            micURL = recordingsDir.appendingPathComponent("ptt_mic.wav")

            Logger.shared.log("Starting recording (PTT mode)...")
        }

        startTime = Date()
        Logger.shared.log("Mic URL: \(micURL?.path ?? "nil")")
        Logger.shared.log("System URL: \(recordingURL?.path ?? "nil")")

        startMicRecording()
        startSystemCapture()
    }
    
    func stop() {
        Logger.shared.log("Stopping recording...")
        
        stopMicRecording()
        
        let shouldAutoPaste = autoPaste
        
        Task {
            // Finish last system chunk before stopping
            self.audioOutput?.finishCurrentChunk()

            try? await systemCapture?.stopCapture()
            Logger.shared.log("System capture stopped")
            systemCapture = nil
            audioFile = nil
            
            // Check file sizes
            if let micURL = micURL {
                let micSize = (try? FileManager.default.attributesOfItem(atPath: micURL.path)[.size] as? Int) ?? 0
                Logger.shared.log("Mic file size: \(micSize) bytes")
            }
            if let sysURL = recordingURL {
                let sysSize = (try? FileManager.default.attributesOfItem(atPath: sysURL.path)[.size] as? Int) ?? 0
                Logger.shared.log("System file size: \(sysSize) bytes")
            }
            
            // Merge and transcribe
            if let sysURL = recordingURL, let micURL = micURL {
                await mergeAndTranscribe(systemURL: sysURL, micURL: micURL, autoPaste: shouldAutoPaste)
            }

            self.isFileRecordingMode = false
            self.sessionDir = nil
        }
    }
    
    private func startMicRecording() {
        guard let url = micURL else { return }
        
        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMicRecordingWithRecorder(url: url)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.startMicRecordingWithRecorder(url: url)
                    }
                } else {
                    Logger.shared.log("Microphone permission denied by user")
                }
            }
        case .denied, .restricted:
            Logger.shared.log("Microphone permission denied or restricted")
        @unknown default:
            Logger.shared.log("Unknown microphone permission status")
        }
    }
    
    private func startMicRecordingWithRecorder(url: URL) {
        startMicWithAudioEngine(url: url)
    }
    
    private func startMicWithAudioEngine(url: URL) {
        Logger.shared.log("Starting mic recording with AVAudioEngine (pre-buffered)...")
        
        // Ensure pre-buffering is running
        if !isPreBuffering {
            startPreBuffering()
            // Give it a moment to start
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        guard let format = preBufferFormat else {
            Logger.shared.log("ERROR: No audio format available")
            onRecordingError?("No microphone detected. Please check your audio input settings.")
            return
        }
        
        Logger.shared.log("Input format: \(format.sampleRate)Hz, \(format.channelCount) channels")
        
        // Write in native format first (will convert after recording)
        let tempURL = url.deletingPathExtension().appendingPathExtension("temp.wav")
        
        do {
            audioInputFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            Logger.shared.log("Audio file created: \(tempURL.path)")
        } catch {
            Logger.shared.log("ERROR creating audio file: \(error.localizedDescription)")
            onRecordingError?("Failed to create audio file: \(error.localizedDescription)")
            return
        }
        
        // Drain ring buffer into file (captures audio from before user pressed record)
        isRecording = true
        var preBufferFrames: UInt32 = 0
        let count = min(preBufferCount, preBuffer.count)
        let startIdx = (preBufferWriteIndex - count + preBuffer.count) % preBuffer.count
        for i in 0..<count {
            let idx = (startIdx + i) % preBuffer.count
            if let buf = preBuffer[idx] {
                try? audioInputFile?.write(from: buf)
                preBufferFrames += buf.frameLength
                preBuffer[idx] = nil
            }
        }
        preBufferCount = 0
        
        let preBufferSeconds = Double(preBufferFrames) / format.sampleRate
        Logger.shared.log("Wrote \(String(format: "%.2f", preBufferSeconds))s of pre-buffer (\(count) buffers)")
        Logger.shared.log("Recording started - capturing live audio")

        // Start first mic chunk for live transcription
        if isFileRecordingMode {
            startNewMicChunk()
        }
    }
    
    private func stopMicRecording() {
        // Stop recording first so finishMicChunk won't start a new chunk
        preBufferLock.lock()
        isRecording = false
        preBufferLock.unlock()

        // Finish last mic chunk
        if isFileRecordingMode, micChunkFile != nil {
            finishMicChunk()
        }

        // Close the audio file
        audioInputFile = nil
        Logger.shared.log("Recording stopped (pre-buffering continues)")
        
        // Convert temp file to 16kHz WAV for whisper
        if let url = micURL {
            let tempURL = url.deletingPathExtension().appendingPathExtension("temp.wav")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                Logger.shared.log("Converting temp audio to 16kHz WAV...")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", tempURL.path, url.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                Logger.shared.log("Conversion complete, removing temp file")
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }
    
    // MARK: - Live Chunk Transcription

    private func resolveWhisperPaths() {
        let bundleURL = Bundle.main.bundleURL
        let bundledWhisper = bundleURL.appendingPathComponent("Contents/Frameworks/whisper/whisper-cli").path
        let systemWhisper = "/opt/homebrew/bin/whisper-cli"
        let bundledModel = bundleURL.appendingPathComponent("Contents/Resources/whisper/ggml-base.en.bin").path
        let systemModel = "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin"

        chunkWhisperPath = FileManager.default.fileExists(atPath: bundledWhisper) ? bundledWhisper :
                           FileManager.default.fileExists(atPath: systemWhisper) ? systemWhisper : nil
        chunkModelPath = FileManager.default.fileExists(atPath: bundledModel) ? bundledModel :
                         FileManager.default.fileExists(atPath: systemModel) ? systemModel : nil
    }

    private func startNewMicChunk() {
        guard isFileRecordingMode, let sessionDir = sessionDir, let format = preBufferFormat else { return }

        let chunksDir = sessionDir.appendingPathComponent("chunks")
        let elapsed = Int(Date().timeIntervalSince(startTime ?? Date()))
        let mins = elapsed / 60
        let secs = elapsed % 60
        let chunkName = String(format: "%02d-%02d_mic.temp.wav", mins, secs)
        let tempURL = chunksDir.appendingPathComponent(chunkName)

        do {
            micChunkFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            micChunkFrameCount = 0
            micChunkOverlapFrames = 0
            chunkIndex += 1

            // Prepend overlap from previous chunk (not for first chunk)
            if chunkIndex > 1 {
                var overlapFrames: UInt32 = 0
                for buffer in micOverlapBuffer {
                    try? micChunkFile?.write(from: buffer)
                    overlapFrames += buffer.frameLength
                }
                micChunkFrameCount = overlapFrames
                micChunkOverlapFrames = overlapFrames
                let overlapSecs = Double(overlapFrames) / format.sampleRate
                Logger.shared.log("Started mic chunk \(chunkIndex) at \(elapsed)s (with \(String(format: "%.1f", overlapSecs))s overlap)")
            } else {
                Logger.shared.log("Started mic chunk \(chunkIndex) at \(elapsed)s")
            }
        } catch {
            Logger.shared.log("ERROR creating mic chunk file: \(error)")
        }
    }

    private func finishMicChunk() {
        guard let sessionDir = sessionDir else { return }

        let tempURL = micChunkFile?.url
        let overlapFrames = micChunkOverlapFrames
        let sampleRate = preBufferFormat?.sampleRate ?? 48000
        let overlapSecs = Double(overlapFrames) / sampleRate
        micChunkFile = nil
        micChunkFrameCount = 0
        micChunkOverlapFrames = 0

        // Start new chunk immediately so we don't miss audio
        if isRecording {
            startNewMicChunk()
        }

        guard let chunkTempURL = tempURL else { return }
        let chunksDir = sessionDir.appendingPathComponent("chunks")
        let chunkName = chunkTempURL.lastPathComponent
            .replacingOccurrences(of: ".temp.wav", with: ".wav")
        let chunkURL = chunksDir.appendingPathComponent(chunkName)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // Convert to 16kHz WAV for whisper (with timeout)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", chunkTempURL.path, chunkURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard self.runWithTimeout(process, timeout: 15) else {
                try? FileManager.default.removeItem(at: chunkTempURL)
                return
            }
            try? FileManager.default.removeItem(at: chunkTempURL)
            self.transcribeChunk(url: chunkURL, source: "mic", chunkName: chunkName, overlapSeconds: overlapSecs)
        }
    }

    private func transcribeChunk(url: URL, source: String, chunkName: String, overlapSeconds: TimeInterval = 0) {
        guard let whisperPath = chunkWhisperPath, let modelPath = chunkModelPath,
              let sessionDir = sessionDir else { return }

        var text: String
        if overlapSeconds > 0 {
            // Use SRT output to filter out overlap portion
            text = transcribeChunkWithOverlap(url: url, overlapSeconds: overlapSeconds, whisperPath: whisperPath, modelPath: modelPath)
        } else {
            text = transcribeChunkSync(url: url, whisperPath: whisperPath, modelPath: modelPath)
        }

        // Write individual chunk txt
        let chunksDir = sessionDir.appendingPathComponent("chunks")
        let txtName = chunkName.replacingOccurrences(of: ".wav", with: ".txt")
        if !text.isEmpty {
            try? text.write(to: chunksDir.appendingPathComponent(txtName), atomically: true, encoding: .utf8)
        }

        // Parse time from chunk name (e.g. "02-15_mic.wav" → "02:15")
        let timeLabel = String(chunkName.prefix(5)) // "02-15"
        let timeStr = timeLabel.replacingOccurrences(of: "-", with: ":")

        if !text.isEmpty {
            let line = "[\(timeStr) \(source)] \(text)\n"
            let transcriptURL = sessionDir.appendingPathComponent("transcript.txt")
            appendToFile(line, at: transcriptURL)
            Logger.shared.log("Chunk [\(timeStr) \(source)] transcribed: \(text.prefix(50))...")
        }
    }

    /// Run a process with a timeout — kills it if it takes too long
    private func runWithTimeout(_ process: Process, timeout: TimeInterval = 30) -> Bool {
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = DispatchTime.now() + timeout
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: deadline) == .timedOut {
            process.terminate()
            Logger.shared.log("WARNING: Process killed after \(Int(timeout))s timeout")
            return false
        }
        return process.terminationStatus == 0
    }

    private func transcribeChunkWithOverlap(url: URL, overlapSeconds: TimeInterval, whisperPath: String, modelPath: String) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size < 1000 {
            return ""
        }

        let outputPath = url.deletingPathExtension().path + "_srt"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["--model", modelPath, "--output-srt", "--output-file", outputPath, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard runWithTimeout(process) else { return "" }

        let srtPath = outputPath + ".srt"
        guard let srt = try? String(contentsOfFile: srtPath, encoding: .utf8) else { return "" }
        try? FileManager.default.removeItem(atPath: srtPath)

        let entries = parseSRT(srt, source: "")
        let filtered = entries.filter { $0.0 >= overlapSeconds - 0.5 }
        return filtered.map { $0.2 }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeChunkSync(url: URL, whisperPath: String, modelPath: String) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size < 1000 {
            return ""
        }

        let outputPath = url.deletingPathExtension().path + "_transcript"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["--model", modelPath, "--output-txt", "--output-file", outputPath, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard runWithTimeout(process) else { return "" }

        let txtPath = outputPath + ".txt"
        if let transcript = try? String(contentsOfFile: txtPath, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: txtPath)
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func appendToFile(_ text: String, at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(text.data(using: .utf8) ?? Data())
                handle.closeFile()
            }
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func startSystemCapture() {
        Logger.shared.log("Starting system capture...")
        
        // Skip if we already know permission was denied
        if SimpleRecorder.hasScreenPermission == false {
            Logger.shared.log("Screen permission previously denied, skipping system capture")
            return
        }
        
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    Logger.shared.log("ERROR: No display found")
                    return
                }
                
                Logger.shared.log("Found display: \(display.displayID)")
                
                // Permission granted - remember this
                SimpleRecorder.hasScreenPermission = true
                
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000  // Match system audio rate — avoid real-time resampling interference
                config.channelCount = 1
                config.width = 2
                config.height = 2
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                self.systemCapture = stream
                
                audioOutput = AudioOutput(url: recordingURL!)
                if self.isFileRecordingMode, let sessionDir = self.sessionDir {
                    self.audioOutput!.chunksDir = sessionDir.appendingPathComponent("chunks")
                    self.audioOutput!.onChunkReady = { [weak self] url, overlapSecs in
                        DispatchQueue.global(qos: .utility).async {
                            self?.transcribeChunk(url: url, source: "audio", chunkName: url.lastPathComponent, overlapSeconds: overlapSecs)
                        }
                    }
                }
                try stream.addStreamOutput(audioOutput!, type: .audio, sampleHandlerQueue: .global())
                try await stream.startCapture()
                Logger.shared.log("System capture started successfully")
            } catch {
                Logger.shared.log("System capture error: \(error.localizedDescription)")
                // If error, permission might be denied
                if SimpleRecorder.hasScreenPermission == nil {
                    SimpleRecorder.hasScreenPermission = false
                }
            }
        }
    }
    
    private func mergeAndTranscribe(systemURL: URL, micURL: URL, autoPaste: Bool) async {
        let timestamp = systemURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_system", with: "")
        Logger.shared.log("Starting transcription for: \(timestamp)")
        
        // Try bundled whisper first (in Frameworks), then fall back to system
        let bundleURL = Bundle.main.bundleURL
        let bundledWhisperPath = bundleURL.appendingPathComponent("Contents/Frameworks/whisper/whisper-cli").path
        let bundledModelPath = bundleURL.appendingPathComponent("Contents/Resources/whisper/ggml-base.en.bin").path
        let systemWhisperPath = "/opt/homebrew/bin/whisper-cli"
        let systemModelPath = "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin"
        
        var whisperPath: String
        var modelPath: String
        
        // Check bundled whisper first
        if FileManager.default.fileExists(atPath: bundledWhisperPath) {
            whisperPath = bundledWhisperPath
            if FileManager.default.fileExists(atPath: bundledModelPath) {
                modelPath = bundledModelPath
            } else if FileManager.default.fileExists(atPath: systemModelPath) {
                modelPath = systemModelPath
            } else {
                Logger.shared.log("ERROR: No whisper model found")
                let txtURL = recordingsDir.appendingPathComponent("\(timestamp).txt")
                let placeholder = "# Recording: \(timestamp)\n\n[Whisper model not found]"
                try? placeholder.write(to: txtURL, atomically: true, encoding: .utf8)
                return
            }
            Logger.shared.log("Using bundled whisper: \(whisperPath)")
            Logger.shared.log("Using model: \(modelPath)")
        } else if FileManager.default.fileExists(atPath: systemWhisperPath) {
            // Fall back to system whisper
            whisperPath = systemWhisperPath
            if FileManager.default.fileExists(atPath: bundledModelPath) {
                modelPath = bundledModelPath
            } else if FileManager.default.fileExists(atPath: systemModelPath) {
                modelPath = systemModelPath
            } else {
                Logger.shared.log("ERROR: No whisper model found")
                let txtURL = recordingsDir.appendingPathComponent("\(timestamp).txt")
                let placeholder = "# Recording: \(timestamp)\n\n[Whisper model not found]"
                try? placeholder.write(to: txtURL, atomically: true, encoding: .utf8)
                return
            }
            Logger.shared.log("Using system whisper: \(whisperPath)")
            Logger.shared.log("Using model: \(modelPath)")
        } else {
            Logger.shared.log("ERROR: whisper-cli not found (bundled or system)")
            let txtURL = recordingsDir.appendingPathComponent("\(timestamp).txt")
            let placeholder = "# Recording: \(timestamp)\n\n[Whisper not available]"
            try? placeholder.write(to: txtURL, atomically: true, encoding: .utf8)
            return
        }
        
        Logger.shared.log("Whisper found, mic file: \(micURL.path)")
        Logger.shared.log("System file: \(systemURL.path)")

        var finalTranscript = ""

        if isFileRecordingMode, let sessionDir = sessionDir {
            // File recording mode: concatenate existing chunk transcripts (no re-run)
            let chunksDir = sessionDir.appendingPathComponent("chunks")
            if let chunkFiles = try? FileManager.default.contentsOfDirectory(atPath: chunksDir.path) {
                let txtFiles = chunkFiles.filter { $0.hasSuffix(".txt") }.sorted()
                for file in txtFiles {
                    let timeLabel = String(file.prefix(5)).replacingOccurrences(of: "-", with: ":")
                    let source = file.contains("_mic") ? "mic" : "audio"
                    if let text = try? String(contentsOfFile: chunksDir.appendingPathComponent(file).path, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            finalTranscript += "[\(timeLabel) \(source)] \(trimmed)\n"
                        }
                    }
                }
            }
            Logger.shared.log("Final transcript built from \(finalTranscript.components(separatedBy: "\n").count - 1) chunk entries")
        } else {
            // PTT mode: run whisper on full files
            let micText = await transcribeAudio(url: micURL, whisperPath: whisperPath, modelPath: modelPath)
            Logger.shared.log("Mic transcription: \(micText.isEmpty ? "(empty)" : "\(micText.count) chars")")
            let sysText = await transcribeAudio(url: systemURL, whisperPath: whisperPath, modelPath: modelPath)
            Logger.shared.log("System transcription: \(sysText.isEmpty ? "(empty)" : "\(sysText.count) chars")")

            if !micText.isEmpty && !sysText.isEmpty {
                finalTranscript = "[mic] \(micText.trimmingCharacters(in: .whitespacesAndNewlines))\n[audio] \(sysText.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else if !micText.isEmpty {
                finalTranscript = micText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !sysText.isEmpty {
                finalTranscript = sysText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Save to file
        let txtDir = sessionDir ?? recordingsDir
        let txtURL = isFileRecordingMode ?
            txtDir.appendingPathComponent("final_transcript.txt") :
            txtDir.appendingPathComponent("\(timestamp).txt")
        try? finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).write(to: txtURL, atomically: true, encoding: .utf8)

        if autoPaste && !finalTranscript.isEmpty {
            Logger.shared.log("PTT: Auto-paste triggered (\(finalTranscript.count) chars)")
            let targetApp = self.savedFrontmostApp
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)

                // Restore focus to the app the user was in when they started recording
                if let app = targetApp, !app.isTerminated {
                    app.activate(options: [.activateIgnoringOtherApps])
                    Logger.shared.log("PTT: Restored focus to \(app.localizedName ?? "app")")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.simulatePaste()
                    Logger.shared.log("PTT: Paste simulated")
                }
            }
        } else if autoPaste {
            Logger.shared.log("PTT: Auto-paste skipped (empty transcript)")
        }

        // PTT mode: clean up temp audio files (they're transient, not user recordings)
        if !isFileRecordingMode {
            try? FileManager.default.removeItem(at: systemURL)
            try? FileManager.default.removeItem(at: micURL)
            // Also remove the transcript file
            let txtURL = recordingsDir.appendingPathComponent("\(timestamp).txt")
            try? FileManager.default.removeItem(at: txtURL)
            Logger.shared.log("PTT: Cleaned up temp files")
        }
    }
    
    private func transcribeAudio(url: URL, whisperPath: String, modelPath: String) async -> String {
        Logger.shared.log("Transcribing: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.shared.log("ERROR: File not found: \(url.path)")
            return ""
        }
        
        // Check if file has content (more than just header)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            Logger.shared.log("File size: \(size) bytes")
            if size < 1000 {
                Logger.shared.log("File too small, skipping")
                return ""
            }
        }
        
        let outputPath = url.deletingPathExtension().path + "_transcript"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["--model", modelPath, "--output-txt", "--output-file", outputPath, url.path]
        
        // Capture stderr to see errors
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let exitCode = process.terminationStatus
            Logger.shared.log("Whisper exit code: \(exitCode)")
            
            if exitCode != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                    Logger.shared.log("Whisper error: \(errorString.prefix(200))")
                }
            }
            
            let txtPath = outputPath + ".txt"
            Logger.shared.log("Looking for transcript at: \(txtPath)")
            
            if FileManager.default.fileExists(atPath: txtPath) {
                if let transcript = try? String(contentsOfFile: txtPath, encoding: .utf8) {
                    Logger.shared.log("Transcript found: \(transcript.count) chars")
                    try? FileManager.default.removeItem(atPath: txtPath)
                    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                Logger.shared.log("Transcript file not found")
            }
        } catch {
            Logger.shared.log("Transcription error: \(error.localizedDescription)")
        }
        
        return ""
    }
    
    private func parseSRT(_ srt: String, source: String) -> [(TimeInterval, String, String)] {
        var entries: [(TimeInterval, String, String)] = []
        let blocks = srt.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 3 else { continue }

            // Line 1: sequence number, Line 2: timestamps, Line 3+: text
            let timeLine = lines[1]
            let text = lines[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)

            guard !text.isEmpty else { continue }

            // Parse "00:00:01,000 --> 00:00:03,000"
            let parts = timeLine.components(separatedBy: " --> ")
            guard let startStr = parts.first else { continue }
            let seconds = parseSRTTime(startStr)

            entries.append((seconds, source, text))
        }

        return entries
    }

    private func parseSRTTime(_ str: String) -> TimeInterval {
        // "00:01:23,456" → seconds
        let cleaned = str.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return 0 }
        return h * 3600 + m * 60 + s
    }

    private func simulatePaste() {
        // Use combinedSessionState to avoid conflicts with physical modifier keys
        // (hidSystemState reflects actual hardware state, which can interfere if Cmd
        // is still considered "held" from the double-tap sequence)
        let source = CGEventSource(stateID: .combinedSessionState)

        // Clear any lingering modifier state so the Cmd+V is clean
        source?.setLocalEventsFilterDuringSuppressionState(.permitLocalKeyboardEvents, state: .eventSuppressionStateSuppressionInterval)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) { // 0x09 = 'v'
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        usleep(10_000) // 10ms between key down and up for reliability

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
    
    private func simulateEnterKey() {
        // Create Return/Enter key event (keycode 0x24 = Return)
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        
        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
        
        Logger.shared.log("Simulated Enter key press")
    }
}

class AudioOutput: NSObject, SCStreamOutput {
    private var audioFile: AVAudioFile?
    private let url: URL
    private var sampleCount = 0
    private var detectedSampleRate: Double = 48000  // Will be set from first sample

    // Chunk support for live transcription
    var chunksDir: URL?
    private var chunkFile: AVAudioFile?
    private var chunkSampleCount: Int = 0
    private var chunkIndex: Int = 0
    private var samplesPerChunk: Int { Int(detectedSampleRate) * 15 }  // 15s
    var onChunkReady: ((URL, TimeInterval) -> Void)?  // (url, overlapSeconds)

    // Overlap buffer for seamless chunk boundaries
    private var overlapBuffer: [AVAudioPCMBuffer] = []
    private var overlapSamples: Int { Int(detectedSampleRate) * 5 }  // 5s
    private var chunkOverlapSampleCount: Int = 0

    private var audioSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: detectedSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    init(url: URL) {
        self.url = url
        super.init()
        Logger.shared.log("AudioOutput initialized for: \(url.path)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        sampleCount += 1
        if sampleCount == 1 {
            // Detect actual sample rate from first sample
            if let desc = sampleBuffer.formatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                detectedSampleRate = asbd.mSampleRate
                Logger.shared.log("First audio sample received from system (rate=\(Int(detectedSampleRate))Hz)")
            } else {
                Logger.shared.log("First audio sample received from system")
            }
        }

        if audioFile == nil {
            setupAudioFile()
        }

        writeSampleBuffer(sampleBuffer)
    }

    private func setupAudioFile() {
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: audioSettings, commonFormat: .pcmFormatInt16, interleaved: true)
            Logger.shared.log("System audio file created: \(url.path)")
        } catch {
            Logger.shared.log("ERROR creating audio file: \(error.localizedDescription)")
        }
    }

    private func startNewSystemChunk() {
        guard let chunksDir = chunksDir else { return }

        let elapsed = chunkIndex * 15
        let mins = elapsed / 60
        let secs = elapsed % 60
        let chunkName = String(format: "%02d-%02d_audio.wav", mins, secs)
        let chunkURL = chunksDir.appendingPathComponent(chunkName)

        do {
            chunkFile = try AVAudioFile(forWriting: chunkURL, settings: audioSettings, commonFormat: .pcmFormatInt16, interleaved: true)
            chunkSampleCount = 0
            chunkOverlapSampleCount = 0
            chunkIndex += 1

            // Prepend overlap from previous chunk (not for first chunk)
            if chunkIndex > 1 {
                var overlapWritten: Int = 0
                for buffer in overlapBuffer {
                    try? chunkFile?.write(from: buffer)
                    overlapWritten += Int(buffer.frameLength)
                }
                chunkSampleCount = overlapWritten
                chunkOverlapSampleCount = overlapWritten
                Logger.shared.log("Started system chunk \(chunkIndex) at \(elapsed)s (with \(String(format: "%.1f", Double(overlapWritten) / detectedSampleRate))s overlap)")
            } else {
                Logger.shared.log("Started system chunk \(chunkIndex) at \(elapsed)s")
            }
        } catch {
            Logger.shared.log("ERROR creating system chunk: \(error)")
        }
    }

    private func finishSystemChunk() {
        let chunkURL = chunkFile?.url
        let overlapSecs = Double(chunkOverlapSampleCount) / detectedSampleRate
        chunkFile = nil
        chunkSampleCount = 0
        chunkOverlapSampleCount = 0

        startNewSystemChunk()

        if let url = chunkURL {
            onChunkReady?(url, overlapSecs)
        }
    }

    func finishCurrentChunk() {
        if let url = chunkFile?.url {
            let overlapSecs = Double(chunkOverlapSampleCount) / detectedSampleRate
            chunkFile = nil
            chunkSampleCount = 0
            chunkOverlapSampleCount = 0
            onChunkReady?(url, overlapSecs)
        }
    }

    private func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let audioFile = audioFile,
              let blockBuffer = sampleBuffer.dataBuffer,
              let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        let channelCount = Int(asbd.mChannelsPerFrame)

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let volumeBoost: Float = 3.0
        let floatData = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: Int(frameCount) * channelCount)

        // Convert to Int16 with volume boost
        if let int16Data = pcmBuffer.int16ChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += floatData[frame * channelCount + channel]
                }
                sample = sample / Float(channelCount) * volumeBoost
                sample = min(1.0, max(-1.0, sample))
                int16Data[frame] = Int16(sample * 32767)
            }
        }

        // Write to main file
        try? audioFile.write(from: pcmBuffer)

        // Write to chunk file for live transcription
        if chunksDir != nil {
            // Maintain overlap buffer (last 5s of PCM buffers)
            overlapBuffer.append(pcmBuffer)
            var totalOverlapSamples = overlapBuffer.reduce(0) { $0 + Int($1.frameLength) }
            while totalOverlapSamples > overlapSamples, !overlapBuffer.isEmpty {
                totalOverlapSamples -= Int(overlapBuffer.first!.frameLength)
                overlapBuffer.removeFirst()
            }

            if chunkFile == nil {
                startNewSystemChunk()
            }
            try? chunkFile?.write(from: pcmBuffer)
            chunkSampleCount += Int(frameCount)

            // Check if new audio (excluding overlap) >= 15s
            let newSamples = chunkSampleCount - chunkOverlapSampleCount
            if newSamples >= samplesPerChunk {
                finishSystemChunk()
            }
        }
    }
}
