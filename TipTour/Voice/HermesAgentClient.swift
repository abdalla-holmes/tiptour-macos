import Foundation

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
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8642/v1/chat/completions")!)
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
