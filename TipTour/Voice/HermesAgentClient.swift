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

    private struct StreamChunk: Decodable {
        let choices: [Choice]?
        let error: StreamError?
    }

    private struct Choice: Decodable {
        let delta: Delta?
    }

    private struct Delta: Decodable {
        let content: String?
    }

    private struct StreamError: Decodable {
        let message: String?
    }

    private struct ToolProgressPayload: Decodable {
        let label: String?
        let tool: String?
        let emoji: String?
    }

    func streamPrompt(
        _ prompt: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onToolProgress: @escaping (String) async -> Void
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
            if eventType == "hermes.tool.progress" {
                if let progress = decodeToolProgress(from: data) {
                    await onToolProgress(progress)
                }
                return false
            }
            if data == "[DONE]" { return true }

            do {
                let decoded = try JSONDecoder().decode(StreamChunk.self, from: Data(data.utf8))
                if let errorMessage = decoded.error?.message, !errorMessage.isEmpty {
                    throw NSError(
                        domain: "HermesAgentClient",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: errorMessage]
                    )
                }

                for choice in decoded.choices ?? [] {
                    if let chunk = choice.delta?.content, !chunk.isEmpty {
                        accumulatedResponseText += chunk
                        await onChunk(accumulatedResponseText)
                    }
                }
            } catch {
                if data.contains("tool") || data.contains("label") {
                    if let progress = decodeToolProgress(from: data) {
                        await onToolProgress(progress)
                    }
                    return false
                }
                throw error
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
            } else if line.hasPrefix("data: ") {
                currentDataLines.append(String(line.dropFirst("data: ".count)))
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

    /v1/targets is the single target graph. It may contain AX/CDP/native OCR/YOLO targets and optional OmniParser parser targets. Prefer target_id or target_mark from that response over fuzzy text labels.

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

    private func decodeToolProgress(from data: String) -> String? {
        guard let decoded = try? JSONDecoder().decode(ToolProgressPayload.self, from: Data(data.utf8)) else {
            return nil
        }
        let label = decoded.label ?? decoded.tool ?? ""
        guard !label.isEmpty else { return nil }
        if let emoji = decoded.emoji, !emoji.isEmpty {
            return "\(emoji) \(label)"
        }
        return label
    }
}
