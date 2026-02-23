import Foundation
import AppKit

/// SecondChair API client for the Murmur daemon.
/// Polls for commands from the web UI and executes them (start/stop recording, etc.)
class SecondChairClient {
    static let shared = SecondChairClient()

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 10.0
    private var isPolling = false

    /// Callback when daemon should start a file recording
    var onStartRecording: ((String?, String?, String?) -> Void)?  // (sessionId, title, meetingLink)
    /// Callback when daemon should stop recording
    var onStopRecording: (() -> Void)?

    private init() {}

    // MARK: - Polling Lifecycle

    func startPolling() {
        guard Settings.shared.isSecondChairConfigured else {
            Logger.shared.log("SecondChair: Not configured, skipping poll start")
            return
        }
        guard !isPolling else { return }

        isPolling = true
        Logger.shared.log("SecondChair: Starting command polling (every \(Int(pollInterval))s)")

        // Poll immediately, then on timer
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        isPolling = false
        Logger.shared.log("SecondChair: Stopped command polling")
    }

    func restartIfNeeded() {
        if Settings.shared.isSecondChairConfigured {
            if !isPolling { startPolling() }
        } else {
            stopPolling()
        }
    }

    // MARK: - Poll & Execute

    private func poll() {
        guard Settings.shared.isSecondChairConfigured else { return }

        let baseURL = Settings.shared.secondChairBaseURL
        let apiKey = Settings.shared.secondChairApiKey

        guard let url = URL(string: "\(baseURL)/daemon/commands") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                Logger.shared.log("SecondChair: Poll error — \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commands = json["commands"] as? [[String: Any]] else {
                return
            }

            if commands.isEmpty { return }

            Logger.shared.log("SecondChair: Received \(commands.count) command(s)")
            for command in commands {
                self?.executeCommand(command)
            }
        }.resume()
    }

    private func executeCommand(_ command: [String: Any]) {
        guard let commandId = command["commandId"] as? String,
              let action = command["action"] as? String else { return }

        Logger.shared.log("SecondChair: Executing command \(commandId) — action: \(action)")

        switch action {
        case "start_recording":
            let sessionId = command["sessionId"] as? String
            let title = command["title"] as? String
            let meetingLink = (command["meetingLink"] as? [String: Any])?["link"] as? String

            // Acknowledge as in_progress
            ackCommand(commandId: commandId, status: "in_progress")

            DispatchQueue.main.async {
                // Open meeting link if provided
                if let link = meetingLink, let url = URL(string: link) {
                    Logger.shared.log("SecondChair: Opening meeting link — \(link)")
                    NSWorkspace.shared.open(url)
                    // Small delay to let the meeting app open
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.onStartRecording?(sessionId, title, meetingLink)
                    }
                } else {
                    self.onStartRecording?(sessionId, title, nil)
                }
            }

        case "stop_recording":
            ackCommand(commandId: commandId, status: "in_progress")
            DispatchQueue.main.async {
                self.onStopRecording?()
            }
            // Mark completed after a short delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.ackCommand(commandId: commandId, status: "completed")
            }

        case "ping":
            ackCommand(commandId: commandId, status: "completed")
            Logger.shared.log("SecondChair: Ping acknowledged")

        default:
            Logger.shared.log("SecondChair: Unknown action — \(action)")
            ackCommand(commandId: commandId, status: "failed", error: "Unknown action: \(action)")
        }
    }

    // MARK: - Acknowledge Command

    func ackCommand(commandId: String, status: String, error errorMsg: String? = nil) {
        let baseURL = Settings.shared.secondChairBaseURL
        let apiKey = Settings.shared.secondChairApiKey

        guard let url = URL(string: "\(baseURL)/daemon/commands/\(commandId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["status": status]
        if let err = errorMsg { body["error"] = err }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Logger.shared.log("SecondChair: Ack error — \(error.localizedDescription)")
                return
            }
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.shared.log("SecondChair: Ack \(commandId) → \(status) (HTTP \(httpCode))")
        }.resume()
    }

    // MARK: - Rotate API Key

    func rotateKey(completion: @escaping (String?) -> Void) {
        let baseURL = Settings.shared.secondChairBaseURL
        let apiKey = Settings.shared.secondChairApiKey

        guard let url = URL(string: "\(baseURL)/daemon/rotate-key") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log("SecondChair: Rotate key error — \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newKey = json["apiKey"] as? String else {
                Logger.shared.log("SecondChair: Rotate key — invalid response")
                completion(nil)
                return
            }

            // Update local settings with new key
            DispatchQueue.main.async {
                Settings.shared.secondChairApiKey = newKey
                Logger.shared.log("SecondChair: API key rotated successfully")
                completion(newKey)
            }
        }.resume()
    }

    // MARK: - Upload Chunk to API

    func uploadChunk(sessionId: String, content: String, sequenceNum: Int, timestamp: String) {
        let baseURL = Settings.shared.secondChairBaseURL
        let apiKey = Settings.shared.secondChairApiKey

        guard let url = URL(string: "\(baseURL)/chunks") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "sessionId": sessionId,
            "content": content,
            "sequenceNum": sequenceNum,
            "timestamp": timestamp,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Logger.shared.log("SecondChair: Chunk upload error — \(error.localizedDescription)")
                return
            }
            let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if httpCode >= 200 && httpCode < 300 {
                Logger.shared.log("SecondChair: Chunk \(sequenceNum) uploaded (HTTP \(httpCode))")
            } else {
                Logger.shared.log("SecondChair: Chunk upload failed (HTTP \(httpCode))")
            }
        }.resume()
    }
}
