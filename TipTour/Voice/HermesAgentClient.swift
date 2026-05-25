import Foundation

enum HermesConnectionState: Equatable {
    case idle
    case checking
    case connected
    case notFound
    case notRunning
    case wrongServer
    case error

    var title: String {
        switch self {
        case .idle: return "Not checked"
        case .checking: return "Checking"
        case .connected: return "Connected"
        case .notFound: return "Not found"
        case .notRunning: return "Not running"
        case .wrongServer: return "Wrong server"
        case .error: return "Error"
        }
    }
}

struct HermesConnectionStatus: Equatable {
    var state: HermesConnectionState
    var baseURL: String
    var detail: String
    var detectedInstallPath: String?

    static let idle = HermesConnectionStatus(
        state: .idle,
        baseURL: TipTourDefaults.hermesAPIBaseURL,
        detail: "Hermes has not been checked yet.",
        detectedInstallPath: nil
    )
}

struct HermesInstallInspection: Equatable {
    let hermesHome: String?
    let isInstalled: Bool
    let isConfigured: Bool
    let inferredBaseURL: String?
}

struct HermesAgentStreamResult {
    let responseText: String
    let sessionID: String?
}

struct HermesAgentClient {
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let sessionID: String?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case sessionID = "session_id"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    func streamPrompt(
        _ prompt: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onToolProgress: @escaping (String) async -> Void,
        onStatus: @escaping (String) async -> Void = { _ in }
    ) async throws -> HermesAgentStreamResult {
        let endpoint = Self.endpointURL(
            baseURL: TipTourDefaults.hermesAPIBaseURL,
            path: "/v1/chat/completions"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: "hermes-agent",
                messages: [
                    Message(role: "system", content: Self.systemPrompt),
                    Message(role: "user", content: prompt)
                ],
                stream: true,
                sessionID: resumeSessionID
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTPResponse(response)
        await onStatus("Hermes connected - waiting for output")

        let sessionID = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "x-hermes-session-id")

        var accumulatedResponseText = ""
        var currentEventType = ""
        var currentDataLines: [String] = []

        func processSSEBlock() async throws -> Bool {
            let eventType = currentEventType
            let data = currentDataLines.joined(separator: "\n")
            currentEventType = ""
            currentDataLines.removeAll()

            guard !data.isEmpty else { return false }
            if data == "[DONE]" { return true }

            guard let object = decodeJSONObject(from: data) else {
                return false
            }

            if let errorMessage = streamErrorMessage(from: object) {
                throw NSError(
                    domain: "HermesAgentClient",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }

            let chunks = assistantContentChunks(from: object, eventType: eventType)
            for chunk in chunks where !chunk.isEmpty {
                accumulatedResponseText += chunk
                await onChunk(accumulatedResponseText)
            }

            if let progress = progressDisplayText(from: object, eventType: eventType) {
                await onToolProgress(progress)
            }
            return false
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                if try await processSSEBlock() { break }
                continue
            }

            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("event:") {
                currentEventType = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                currentDataLines.append(String(line.dropFirst("data: ".count)))
            } else if line.hasPrefix("data:") {
                currentDataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        if !currentDataLines.isEmpty {
            _ = try await processSSEBlock()
        }

        return HermesAgentStreamResult(
            responseText: accumulatedResponseText,
            sessionID: sessionID ?? resumeSessionID
        )
    }

    private static let systemPrompt = """
    You are Hermes running behind TipTour.

    TipTour is the local macOS pointer, perception, and action layer. When a user asks for desktop help, use TipTour through its localhost HTTP harness instead of guessing coordinates yourself.

    TipTour endpoints:
    - GET http://127.0.0.1:19474/v1/observe
    - GET http://127.0.0.1:19474/v1/skills
    - GET http://127.0.0.1:19474/v1/skills/active
    - GET http://127.0.0.1:19474/v1/targets
    - GET http://127.0.0.1:19474/v1/action-history
    - POST http://127.0.0.1:19474/v1/plan-next-action
    - POST http://127.0.0.1:19474/v1/workflow-plan

    /v1/targets is the single target graph. It may contain AX/CDP/native OCR/YOLO targets. Prefer target_id or target_mark from that response over fuzzy text labels.

    Check /v1/skills/active when an app has quirks. Use those markdown skill instructions as app-specific guidance, but still execute through TipTour's one-action endpoints.

    Prefer one desktop action at a time. For simple visible clicks, call /v1/plan-next-action with JSON like:
    {"goal":"open the Add menu","app":"Blender","target_label":"Add","action":"click","execute":true}

    For keyboard or app actions, call /v1/workflow-plan with exactly one step. TipTour clamps to one action and will handle local grounding, pointer animation, clicking, typing, validation, and repair.

    Workflow-plan examples:
    - Press a key: {"goal":"press return","app":"Target App","steps":[{"type":"pressKey","label":"Return"}]}
    - Type text/numbers: {"goal":"type value","app":"Target App","steps":[{"type":"type","value":"hello"}]}
    - Keyboard shortcut: {"goal":"select all","app":"Target App","steps":[{"type":"keyboardShortcut","label":"Cmd+A"}]}
    Never send pressKey without label/key. Never send type without value/text.

    Keep user-facing replies short. Explain what you are doing while tools run. Do not claim an action succeeded until TipTour returns success or a useful observation.
    """

    func detectLocalConnection() async -> HermesConnectionStatus {
        let inspection = Self.inspectLocalInstallation()
        var candidateBaseURLs: [String] = []
        if let inferredBaseURL = inspection.inferredBaseURL {
            candidateBaseURLs.append(inferredBaseURL)
        }
        candidateBaseURLs.append(TipTourDefaults.hermesAPIBaseURL)
        candidateBaseURLs.append("http://127.0.0.1:8642")
        candidateBaseURLs.append(contentsOf: (8643...8662).map { "http://127.0.0.1:\($0)" })
        candidateBaseURLs = uniqueNormalizedBaseURLs(candidateBaseURLs)

        for candidateBaseURL in candidateBaseURLs {
            let status = await testConnection(baseURL: candidateBaseURL)
            switch status.state {
            case .connected, .wrongServer:
                return HermesConnectionStatus(
                    state: status.state,
                    baseURL: status.baseURL,
                    detail: status.detail,
                    detectedInstallPath: inspection.hermesHome
                )
            default:
                continue
            }
        }

        if inspection.isInstalled {
            return HermesConnectionStatus(
                state: .notRunning,
                baseURL: candidateBaseURLs.first ?? "http://127.0.0.1:8642",
                detail: "Hermes is installed but the API server is not reachable. Start the gateway with API_SERVER_ENABLED=true hermes gateway run.",
                detectedInstallPath: inspection.hermesHome
            )
        }

        return HermesConnectionStatus(
            state: .notFound,
            baseURL: "http://127.0.0.1:8642",
            detail: "No Hermes install or API server was found on localhost.",
            detectedInstallPath: inspection.hermesHome
        )
    }

    func testConnection(baseURL: String) async -> HermesConnectionStatus {
        let normalizedBaseURL = Self.normalizedBaseURL(baseURL)

        do {
            let health = try await httpStatus(baseURL: normalizedBaseURL, path: "/health")
            guard (200..<300).contains(health) else {
                return HermesConnectionStatus(
                    state: .notRunning,
                    baseURL: normalizedBaseURL,
                    detail: "No healthy Hermes API server answered on \(normalizedBaseURL).",
                    detectedInstallPath: nil
                )
            }

            let capabilities = try? await jsonObject(baseURL: normalizedBaseURL, path: "/v1/capabilities")
            let models = try? await jsonObject(baseURL: normalizedBaseURL, path: "/v1/models")
            let looksLikeHermes = Self.responseLooksLikeHermes(capabilities: capabilities, models: models)
            return HermesConnectionStatus(
                state: looksLikeHermes ? .connected : .wrongServer,
                baseURL: normalizedBaseURL,
                detail: looksLikeHermes
                    ? "Hermes API server is reachable at \(normalizedBaseURL)."
                    : "A server answered on \(normalizedBaseURL), but it does not look like Hermes.",
                detectedInstallPath: nil
            )
        } catch {
            return HermesConnectionStatus(
                state: .notRunning,
                baseURL: normalizedBaseURL,
                detail: "No Hermes API server answered on \(normalizedBaseURL).",
                detectedInstallPath: nil
            )
        }
    }

    static func inspectLocalInstallation() -> HermesInstallInspection {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path
        let environmentHome = ProcessInfo.processInfo.environment["HERMES_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [environmentHome, "\(homeDirectory)/.hermes"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let hermesHome = candidates.first(where: { looksLikeHermesHome($0) })
        guard let hermesHome else {
            return HermesInstallInspection(
                hermesHome: nil,
                isInstalled: false,
                isConfigured: false,
                inferredBaseURL: nil
            )
        }

        let repoPath = "\(hermesHome)/hermes-agent"
        let pythonPath = "\(repoPath)/venv/bin/python"
        let scriptPath = "\(repoPath)/hermes"
        let isInstalled = fileManager.fileExists(atPath: pythonPath)
            && fileManager.fileExists(atPath: scriptPath)
        let configPath = "\(hermesHome)/config.yaml"
        let envPath = "\(hermesHome)/.env"
        let authPath = "\(hermesHome)/auth.json"
        let isConfigured = fileManager.fileExists(atPath: configPath)
            || fileManager.fileExists(atPath: envPath)
            || fileManager.fileExists(atPath: authPath)

        let envText = (try? String(contentsOfFile: envPath, encoding: .utf8)) ?? ""
        let configText = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let host = firstConfigValue(named: "API_SERVER_HOST", in: envText)
            ?? firstConfigValue(named: "host", in: configText)
            ?? "127.0.0.1"
        let port = firstConfigValue(named: "API_SERVER_PORT", in: envText)
            ?? firstConfigValue(named: "port", in: configText)
            ?? "8642"
        let inferredBaseURL = "http://\(host):\(port)"

        return HermesInstallInspection(
            hermesHome: hermesHome,
            isInstalled: isInstalled,
            isConfigured: isConfigured,
            inferredBaseURL: inferredBaseURL
        )
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "HermesAgentClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hermes API request failed with HTTP \(httpResponse.statusCode)."]
            )
        }
    }

    private func httpStatus(baseURL: String, path: String) async throws -> Int {
        var request = URLRequest(url: Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func jsonObject(baseURL: String, path: String) async throws -> [String: Any]? {
        var request = URLRequest(url: Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            return nil
        }
        return decodeJSONObject(from: String(decoding: data, as: UTF8.self))
    }

    private func uniqueNormalizedBaseURLs(_ baseURLs: [String]) -> [String] {
        var seen = Set<String>()
        return baseURLs.compactMap { rawURL in
            let normalizedURL = Self.normalizedBaseURL(rawURL)
            guard !seen.contains(normalizedURL) else { return nil }
            seen.insert(normalizedURL)
            return normalizedURL
        }
    }

    static func normalizedBaseURL(_ rawURL: String) -> String {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            value = "http://127.0.0.1:8642"
        }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://\(value)"
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.lowercased().hasSuffix("/v1") {
            value.removeLast(3)
        }
        return value
    }

    static func endpointURL(baseURL: String, path: String) -> URL {
        let normalizedBaseURL = normalizedBaseURL(baseURL)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalizedBaseURL + normalizedPath)
            ?? URL(string: "http://127.0.0.1:8642\(normalizedPath)")!
    }

    private static func looksLikeHermesHome(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: "\(path)/hermes-agent")
            || fileManager.fileExists(atPath: "\(path)/gateway.pid")
            || fileManager.fileExists(atPath: "\(path)/config.yaml")
            || fileManager.fileExists(atPath: "\(path)/active_profile")
            || fileManager.fileExists(atPath: "\(path)/.env")
    }

    private static func firstConfigValue(named key: String, in text: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"(?m)^\s*(KEY)\s*[:=]\s*["']?([^"'\n#]+)"#
        ].map { $0.replacingOccurrences(of: "KEY", with: escapedKey) }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let valueRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            let value = String(text[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func responseLooksLikeHermes(
        capabilities: [String: Any]?,
        models: [String: Any]?
    ) -> Bool {
        if let object = capabilities?["object"] as? String,
           object == "hermes.api_server.capabilities" {
            return true
        }
        if let models,
           String(describing: models).lowercased().contains("hermes") {
            return true
        }
        return false
    }

    private func decodeJSONObject(from data: String) -> [String: Any]? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
            let object = jsonObject as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func streamErrorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    private func assistantContentChunks(from object: [String: Any], eventType: String) -> [String] {
        var chunks: [String] = []

        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    chunks.append(content)
                }
                if let message = choice["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.isEmpty {
                    chunks.append(content)
                }
                if let text = choice["text"] as? String, !text.isEmpty {
                    chunks.append(text)
                }
            }
        }

        if eventType == "response.output_text.delta",
           let delta = object["delta"] as? String,
           !delta.isEmpty {
            chunks.append(delta)
        }

        for key in ["content", "text", "response"] {
            if let value = object[key] as? String, !value.isEmpty {
                chunks.append(value)
            }
        }

        return chunks
    }

    private func progressDisplayText(from object: [String: Any], eventType: String) -> String? {
        let lowercasedEventType = eventType.lowercased()
        let looksLikeProgressEvent = lowercasedEventType.contains("progress")
            || lowercasedEventType.contains("tool")
            || lowercasedEventType.contains("status")
            || object["tool"] != nil
            || object["toolCallId"] != nil
            || object["status"] != nil
            || object["label"] != nil
        guard looksLikeProgressEvent else { return nil }

        let label = firstString(in: object, keys: ["label", "message", "preview", "text", "content"])
        let tool = firstString(in: object, keys: ["tool", "name", "function", "type"])
        let status = firstString(in: object, keys: ["status", "state"])
        let emoji = firstString(in: object, keys: ["emoji"])
        let baseText = label ?? tool ?? status ?? eventType
        guard !baseText.isEmpty else { return nil }

        var displayText: String
        switch status?.lowercased() {
        case "completed", "complete", "done", "success", "succeeded":
            displayText = "Finished \(label ?? tool ?? "tool")"
        case "failed", "error":
            displayText = "Failed \(label ?? tool ?? "tool")"
        case "running", "started", "in_progress":
            displayText = baseText
        default:
            displayText = baseText
        }

        if let emoji, !emoji.isEmpty, !displayText.hasPrefix(emoji) {
            displayText = "\(emoji) \(displayText)"
        }
        return displayText
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty {
                    return trimmedValue
                }
            }
        }
        return nil
    }
}
