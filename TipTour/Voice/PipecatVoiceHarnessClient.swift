//
//  PipecatVoiceHarnessClient.swift
//  TipTour
//
//  Lightweight contract for a local Pipecat sidecar. TipTour remains the
//  macOS pointer/action engine; Pipecat can own realtime voice I/O and call
//  the local TipTour and Hermes HTTP tools.
//

import Foundation

struct PipecatVoiceHarnessHealth: Decodable {
    let ok: Bool
    let service: String?
    let message: String?
}

struct PipecatVoiceHarnessClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:7860")!

    let baseURL: URL

    init(baseURL: URL = Self.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func health() async throws -> PipecatVoiceHarnessHealth {
        let url = baseURL.appendingPathComponent("v1/health")
        let (data, response) = try await URLSession.shared.data(from: url)
        try ProviderRequestDiagnostics.validateHTTPResponse(
            response,
            data: data,
            serviceName: "Pipecat harness health",
            errorDomain: "PipecatVoiceHarnessClient"
        )
        return try JSONDecoder().decode(PipecatVoiceHarnessHealth.self, from: data)
    }

    static let tipTourToolInstructions = """
    You are Pipecat running as TipTour's local realtime voice harness.

    TipTour is the macOS pointer, perception, and action engine. Do not guess desktop coordinates yourself. Use TipTour's localhost harness for observation, grounding, pointer animation, and actions.

    TipTour tools:
    - GET http://127.0.0.1:19474/v1/observe
    - GET http://127.0.0.1:19474/v1/skills
    - GET http://127.0.0.1:19474/v1/skills/active
    - GET http://127.0.0.1:19474/v1/targets
    - GET http://127.0.0.1:19474/v1/action-history
    - POST http://127.0.0.1:19474/v1/plan-next-action
    - POST http://127.0.0.1:19474/v1/workflow-plan

    For visible UI clicks, prefer /v1/targets and /v1/plan-next-action with target_id or target_mark. For keys, typing, app launch, and scrolling, use /v1/workflow-plan with exactly one step. TipTour executes one action at a time and validates after each action.
    """

    static let hermesDelegationInstructions = """
    Hermes is the optional long-horizon planner. Use it when the user asks for a multi-step task, repeated work, memory-heavy reasoning, or a workflow that needs to continue across many observations.

    Hermes endpoint:
    - POST http://127.0.0.1:8642/v1/chat/completions

    Pipecat should not duplicate Hermes planning. For long tasks, delegate the high-level request to Hermes and let Hermes call TipTour's harness tools. Keep realtime voice responses short while Hermes works.
    """
}
