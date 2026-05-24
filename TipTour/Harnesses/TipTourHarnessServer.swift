//
//  TipTourHarnessServer.swift
//  TipTour
//
//  Local-only HTTP harness for external orchestrators such as Hermes.
//  The server deliberately exposes TipTour's existing local engine instead
//  of embedding any external agent runtime inside the macOS app.
//

import AppKit
import Foundation
import Network

@MainActor
final class TipTourHarnessServer {
    private let tipTourEngine: TipTourEngine
    private let port: NWEndpoint.Port
    private let activityReporter: @MainActor (String) -> Void
    private var listener: NWListener?

    init(
        tipTourEngine: TipTourEngine,
        port: UInt16 = 19474,
        activityReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.tipTourEngine = tipTourEngine
        self.port = NWEndpoint.Port(rawValue: port) ?? 19474
        self.activityReporter = activityReporter
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            if let loopbackAddress = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(loopbackAddress),
                    port: port
                )
            }

            let listener = try NWListener(using: parameters)
            configureAndStart(listener)
            self.listener = listener
        } catch {
            print("[Harness] failed to start local harness: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func configureAndStart(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection: connection)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Harness] TipTour local harness listening on http://127.0.0.1:\(self.port)")
            case .failed(let error):
                print("[Harness] local harness failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: .main)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPData(from: connection, buffer: Data())
    }

    private func receiveHTTPData(from connection: NWConnection, buffer requestData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("[Harness] receive failed: \(error)")
                connection.cancel()
                return
            }

            var updatedRequestData = requestData
            if let data {
                updatedRequestData.append(data)
            }

            if self.requestDataIsComplete(updatedRequestData) || isComplete {
                Task { @MainActor in
                    await self.respond(to: updatedRequestData, on: connection)
                }
            } else {
                self.receiveHTTPData(from: connection, buffer: updatedRequestData)
            }
        }
    }

    private func requestDataIsComplete(_ requestData: Data) -> Bool {
        guard let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }

        let headerData = requestData[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                let value = line.split(separator: ":", maxSplits: 1).dropFirst().joined()
                return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 0

        let bodyStartIndex = headerRange.upperBound
        return requestData.count - bodyStartIndex >= contentLength
    }

    private func respond(to requestData: Data, on connection: NWConnection) async {
        let request = parseRequest(requestData)

        let response: HarnessHTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            response = jsonResponse(["ok": true, "service": "tiptour-harness"])
        case ("GET", "/v1/capabilities"):
            activityReporter("Hermes checking TipTour capabilities")
            response = jsonResponse([
                "ok": true,
                "tools": [
                    "tiptour.observe",
                    "tiptour.skills",
                    "tiptour.active_skill",
                    "tiptour.targets",
                    "tiptour.plan_next_action",
                    "tiptour.action_history",
                    "tiptour.submit_workflow_plan"
                ],
                "single_action": true,
                "transport": "localhost-http"
            ])
        case ("GET", "/v1/observe"):
            activityReporter("Hermes observing the desktop")
            response = encodableResponse(tipTourEngine.observe())
        case ("GET", "/v1/skills"):
            activityReporter("Hermes reading app skills")
            response = encodableResponse(tipTourEngine.skills())
        case ("GET", "/v1/skills/active"), ("GET", "/v1/active-skill"), ("GET", "/v1/active_skill"):
            activityReporter("Hermes reading the active app skill")
            response = encodableResponse(tipTourEngine.activeSkill())
        case ("GET", "/v1/targets"), ("GET", "/v1/grounding-targets"):
            activityReporter("Hermes checking screen targets")
            response = await handleTargetsRequest()
        case ("GET", "/v1/action-history"), ("GET", "/v1/action_history"):
            activityReporter("Hermes checking recent actions")
            response = encodableResponse(tipTourEngine.actionHistory())
        case ("POST", "/v1/plan-next-action"), ("POST", "/v1/plan_next_action"):
            activityReporter("Hermes planning the next action")
            response = await handlePlanNextActionRequest(body: request.body)
        case ("POST", "/v1/workflow-plan"), ("POST", "/v1/submit_workflow_plan"):
            response = handleWorkflowPlanRequest(body: request.body)
        default:
            response = jsonResponse(
                ["ok": false, "reason": "not_found"],
                statusCode: 404,
                statusText: "Not Found"
            )
        }

        connection.send(content: response.data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleTargetsRequest() async -> HarnessHTTPResponse {
        let targets = await tipTourEngine.localPerceptionTargets(
            refresh: true,
            reason: "harness /v1/targets"
        )
        return encodableResponse(targets)
    }

    private func handlePlanNextActionRequest(body: Data) async -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessPlanNextActionRequest.self, from: body)
            let result = await tipTourEngine.runPointerAction(request.pointerActionRequest)
            return encodableResponse(result)
        } catch {
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func handleWorkflowPlanRequest(body: Data) -> HarnessHTTPResponse {
        do {
            let request = try JSONDecoder().decode(HarnessWorkflowPlanRequest.self, from: body)
            let plan = request.toWorkflowPlan()
            let result = tipTourEngine.submitSingleActionWorkflowPlan(plan)
            return encodableResponse(result)
        } catch {
            return jsonResponse(
                [
                    "ok": false,
                    "reason": "invalid_request",
                    "message": error.localizedDescription
                ],
                statusCode: 400,
                statusText: "Bad Request"
            )
        }
    }

    private func parseRequest(_ requestData: Data) -> HarnessHTTPRequest {
        guard let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) else {
            return HarnessHTTPRequest(method: "", path: "", body: Data())
        }

        let headerData = requestData[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let requestLine = headerText.split(separator: "\r\n").first ?? ""
        let requestLineParts = requestLine.split(separator: " ")
        let method = requestLineParts.first.map(String.init) ?? ""
        let rawPath = requestLineParts.dropFirst().first.map(String.init) ?? ""
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let body = requestData[headerRange.upperBound...]

        return HarnessHTTPRequest(method: method, path: path, body: Data(body))
    }

    private func encodableResponse<T: Encodable>(_ value: T) -> HarnessHTTPResponse {
        do {
            let data = try JSONEncoder().encode(value)
            return httpResponse(body: data)
        } catch {
            return jsonResponse(
                ["ok": false, "reason": "encoding_failed"],
                statusCode: 500,
                statusText: "Internal Server Error"
            )
        }
    }

    private func jsonResponse(
        _ payload: [String: Any],
        statusCode: Int = 200,
        statusText: String = "OK"
    ) -> HarnessHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        return httpResponse(body: data, statusCode: statusCode, statusText: statusText)
    }

    private func httpResponse(
        body: Data,
        statusCode: Int = 200,
        statusText: String = "OK"
    ) -> HarnessHTTPResponse {
        var responseData = Data()
        responseData.append(Data("HTTP/1.1 \(statusCode) \(statusText)\r\n".utf8))
        responseData.append(Data("Content-Type: application/json\r\n".utf8))
        responseData.append(Data("Content-Length: \(body.count)\r\n".utf8))
        responseData.append(Data("Connection: close\r\n".utf8))
        responseData.append(Data("Access-Control-Allow-Origin: http://127.0.0.1\r\n".utf8))
        responseData.append(Data("\r\n".utf8))
        responseData.append(body)
        return HarnessHTTPResponse(data: responseData)
    }
}

private struct HarnessHTTPRequest {
    let method: String
    let path: String
    let body: Data
}

private struct HarnessHTTPResponse {
    let data: Data
}

private struct HarnessPlanNextActionRequest: Decodable {
    let goal: String
    let app: String?
    let type: String?
    let action: String?
    let label: String?
    let targetLabel: String?
    let target_label: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let execute: Bool?
    let allowScreenshotPlanning: Bool?
    let allow_screenshot_planning: Bool?
    let validateStateChange: Bool?
    let validate_state_change: Bool?

    var pointerActionRequest: PointerActionRequest {
        PointerActionRequest(
            goal: goal,
            app: app,
            actionType: WorkflowStep.StepType.normalized(from: type ?? action),
            targetLabel: targetLabel ?? target_label ?? label,
            targetID: targetID ?? target_id,
            targetMark: targetMark ?? target_mark,
            execute: execute ?? true,
            allowScreenshotPlanning: allowScreenshotPlanning ?? allow_screenshot_planning ?? false,
            validateStateChange: validateStateChange ?? validate_state_change ?? true
        )
    }
}

private struct HarnessWorkflowPlanRequest: Decodable {
    let goal: String
    let app: String?
    let steps: [HarnessWorkflowStepRequest]

    func toWorkflowPlan() -> WorkflowPlan {
        WorkflowPlan(
            goal: goal,
            app: app,
            steps: steps.enumerated().map { index, step in
                step.toWorkflowStep(index: index)
            }
        )
    }
}

private struct HarnessWorkflowStepRequest: Decodable {
    let id: String?
    let type: String?
    let action: String?
    let label: String?
    let targetLabel: String?
    let target_label: String?
    let targetID: String?
    let target_id: String?
    let targetMark: Int?
    let target_mark: Int?
    let key: String?
    let shortcut: String?
    let value: String?
    let text: String?
    let direction: String?
    let amount: Int?
    let by: String?
    let hint: String?
    let targetContext: String?
    let target_context: String?
    let point_2d: [Int]?
    let box_2d: [Int]?
    let screenNumber: Int?
    let screen: Int?

    func toWorkflowStep(index: Int) -> WorkflowStep {
        let normalizedPointBox = point_2d.flatMap { point -> [Int]? in
            guard point.count == 2 else { return nil }
            return [point[0], point[1], point[0], point[1]]
        }

        return WorkflowStep(
            id: id ?? "harness_step_\(index + 1)",
            type: WorkflowStep.StepType.normalized(from: type ?? action),
            label: label ?? targetLabel ?? target_label ?? key ?? shortcut,
            targetID: targetID ?? target_id,
            targetMark: targetMark ?? target_mark,
            value: value ?? text,
            direction: direction,
            amount: amount,
            by: by,
            targetContext: WorkflowStep.TargetContext.normalized(from: targetContext ?? target_context),
            hint: hint ?? "",
            hintX: nil,
            hintY: nil,
            box2DNormalized: box_2d ?? normalizedPointBox,
            screenNumber: screenNumber ?? screen
        )
    }
}
