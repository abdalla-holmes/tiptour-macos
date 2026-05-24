//
//  TipTourEngine.swift
//  TipTour
//
//  Thin engine facade for callers that should not know about
//  CompanionManager. Keep this small: it centralizes observe + one-action
//  workflow submission before we add richer ground/act/record APIs.
//

import AppKit
import Foundation

struct TipTourEngineSubmissionResult: Encodable {
    let ok: Bool
    let reason: String?
    let message: String?
    let acceptedSteps: Int
    let ignoredSteps: Int
    let activeApp: String?
}

struct TipTourEngineObservation: Encodable {
    let ok: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let activePlanGoal: String?
    let isAutopilotEnabled: Bool
    let isScreenshotStreamingEnabled: Bool
    let isAccurateGroundingEnabled: Bool
    let isCuaActionDriverEnabled: Bool
    let isHermesOrchestratorEnabled: Bool
    let isOmniParserHarnessEnabled: Bool
    let detectionElementCount: Int
}

struct TipTourEngineSkillList: Encodable {
    let ok: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let skillCount: Int
    let skills: [MarkdownAppSkillInfo]
}

struct TipTourEngineActiveSkill: Encodable {
    let ok: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let skill: MarkdownAppSkillInfo?
}

struct TipTourEngineTargetList: Encodable {
    let ok: Bool
    let refreshed: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let targetCount: Int
    let targets: [LocalPerceptionTargetCache.SnapshotTarget]
}

struct TipTourEnginePlannedActionStep: Encodable {
    let type: String
    let label: String
    let targetID: String
    let targetMark: Int
    let hint: String
    let box2D: [Int]
    let matchedSource: String
    let matchedConfidence: Double
}

struct TipTourEngineWorkflowOutcome: Encodable {
    let status: String
    let reason: String?
    let message: String?
    let waitMs: Int
}

struct TipTourEngineActionValidation: Encodable {
    let stateChanged: Bool
    let requiredStateChange: Bool
    let beforeTargetCount: Int
    let afterTargetCount: Int
}

struct TipTourEngineActionAttempt: Encodable {
    let attemptNumber: Int
    let timestamp: String
    let target: LocalPerceptionTargetCache.SnapshotTarget
    let plannedStep: TipTourEnginePlannedActionStep
    let submission: TipTourEngineSubmissionResult
    let workflowOutcome: TipTourEngineWorkflowOutcome
    let validation: TipTourEngineActionValidation
}

struct TipTourEngineActionHistory: Encodable {
    let ok: Bool
    let attempts: [TipTourEngineActionAttempt]
}

struct TipTourEnginePlanNextActionResult: Encodable {
    let ok: Bool
    let reason: String?
    let message: String?
    let activeApp: String?
    let plannedStep: TipTourEnginePlannedActionStep?
    let submission: TipTourEngineSubmissionResult?
    let workflowOutcome: TipTourEngineWorkflowOutcome?
    let validation: TipTourEngineActionValidation?
    let attempts: [TipTourEngineActionAttempt]
    let repaired: Bool
    let targets: [LocalPerceptionTargetCache.SnapshotTarget]
}

@MainActor
final class TipTourEngine {
    private let isAutopilotEnabledProvider: () -> Bool
    private let isScreenshotStreamingEnabledProvider: () -> Bool
    private let isAccurateGroundingEnabledProvider: () -> Bool
    private let isCuaActionDriverEnabledProvider: () -> Bool
    private let isHermesOrchestratorEnabledProvider: () -> Bool
    private let isOmniParserHarnessEnabledProvider: () -> Bool
    private let detectionElementCountProvider: () -> Int
    private let refreshLocalPerception: (String) async -> Void
    private let normalizeWorkflowSteps: ([WorkflowStep], String) -> [WorkflowStep]
    private let startWorkflowPlan: (WorkflowPlan) -> Void
    private var recentActionAttempts: [TipTourEngineActionAttempt] = []
    private let maximumRecentActionAttempts = 24
    private let workflowSettlementTimeoutSeconds: TimeInterval = 7.0

    init(
        isAutopilotEnabledProvider: @escaping () -> Bool,
        isScreenshotStreamingEnabledProvider: @escaping () -> Bool,
        isAccurateGroundingEnabledProvider: @escaping () -> Bool,
        isCuaActionDriverEnabledProvider: @escaping () -> Bool,
        isHermesOrchestratorEnabledProvider: @escaping () -> Bool,
        isOmniParserHarnessEnabledProvider: @escaping () -> Bool,
        detectionElementCountProvider: @escaping () -> Int,
        refreshLocalPerception: @escaping (String) async -> Void,
        normalizeWorkflowSteps: @escaping ([WorkflowStep], String) -> [WorkflowStep],
        startWorkflowPlan: @escaping (WorkflowPlan) -> Void
    ) {
        self.isAutopilotEnabledProvider = isAutopilotEnabledProvider
        self.isScreenshotStreamingEnabledProvider = isScreenshotStreamingEnabledProvider
        self.isAccurateGroundingEnabledProvider = isAccurateGroundingEnabledProvider
        self.isCuaActionDriverEnabledProvider = isCuaActionDriverEnabledProvider
        self.isHermesOrchestratorEnabledProvider = isHermesOrchestratorEnabledProvider
        self.isOmniParserHarnessEnabledProvider = isOmniParserHarnessEnabledProvider
        self.detectionElementCountProvider = detectionElementCountProvider
        self.refreshLocalPerception = refreshLocalPerception
        self.normalizeWorkflowSteps = normalizeWorkflowSteps
        self.startWorkflowPlan = startWorkflowPlan
    }

    func observe() -> TipTourEngineObservation {
        let activeApp = NSWorkspace.shared.frontmostApplication
        return TipTourEngineObservation(
            ok: true,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            activePlanGoal: WorkflowRunner.shared.activePlan?.goal,
            isAutopilotEnabled: isAutopilotEnabledProvider(),
            isScreenshotStreamingEnabled: isScreenshotStreamingEnabledProvider(),
            isAccurateGroundingEnabled: isAccurateGroundingEnabledProvider(),
            isCuaActionDriverEnabled: isCuaActionDriverEnabledProvider(),
            isHermesOrchestratorEnabled: isHermesOrchestratorEnabledProvider(),
            isOmniParserHarnessEnabled: isOmniParserHarnessEnabledProvider(),
            detectionElementCount: detectionElementCountProvider()
        )
    }

    func localPerceptionTargets(refresh: Bool, reason: String = "harness requested targets") async -> TipTourEngineTargetList {
        if refresh {
            await refreshLocalPerception(reason)
        }

        let activeApp = NSWorkspace.shared.frontmostApplication
        let targets = LocalPerceptionTargetCache.shared.currentTargets()
        return TipTourEngineTargetList(
            ok: true,
            refreshed: refresh,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            targetCount: targets.count,
            targets: targets
        )
    }

    func actionHistory() -> TipTourEngineActionHistory {
        TipTourEngineActionHistory(
            ok: true,
            attempts: recentActionAttempts
        )
    }

    func skills() -> TipTourEngineSkillList {
        let activeApp = NSWorkspace.shared.frontmostApplication
        let skillInfos = MarkdownAppSkillRegistry.shared.skillInfos(activeApplication: activeApp)
        return TipTourEngineSkillList(
            ok: true,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            skillCount: skillInfos.count,
            skills: skillInfos
        )
    }

    func activeSkill() -> TipTourEngineActiveSkill {
        let activeApp = NSWorkspace.shared.frontmostApplication
        return TipTourEngineActiveSkill(
            ok: true,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            skill: MarkdownAppSkillRegistry.shared.activeSkillInfo(for: activeApp)
        )
    }

    func planNextAction(
        goal: String,
        app: String?,
        requestedActionType: WorkflowStep.StepType,
        requestedTargetLabel: String?,
        execute: Bool,
        allowScreenshotPlanning: Bool,
        validateStateChange: Bool
    ) async -> TipTourEnginePlanNextActionResult {
        let pointerActionRequest = PointerActionRequest(
            goal: goal,
            app: app,
            actionType: requestedActionType,
            targetLabel: requestedTargetLabel,
            targetID: nil,
            targetMark: nil,
            execute: execute,
            allowScreenshotPlanning: allowScreenshotPlanning,
            validateStateChange: validateStateChange
        )
        return await runPointerAction(pointerActionRequest)
    }

    func runPointerAction(_ pointerActionRequest: PointerActionRequest) async -> TipTourEnginePlanNextActionResult {
        await activateRequestedApplicationForPerceptionIfNeeded(pointerActionRequest.app)
        await refreshLocalPerception("harness plan-next-action")

        let targets = LocalPerceptionTargetCache.shared.currentTargets()
        guard !targets.isEmpty else {
            return TipTourEnginePlanNextActionResult(
                ok: false,
                reason: "no_local_targets",
                message: "No local YOLO/OCR targets are available yet. Turn on Accurate Grounding or wait for a fresh perception pass.",
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: nil,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: []
            )
        }

        let didRequestExactTarget = didRequestExplicitTarget(
            targetID: pointerActionRequest.targetID,
            targetMark: pointerActionRequest.targetMark
        )
        let explicitlyMatchedTarget = explicitTarget(
            requestedTargetID: pointerActionRequest.targetID,
            requestedTargetMark: pointerActionRequest.targetMark,
            targets: targets
        )
        let matchedTarget = explicitlyMatchedTarget ?? (didRequestExactTarget ? nil : bestTarget(
            requestedLabel: pointerActionRequest.targetLabel,
            goal: pointerActionRequest.goal,
            targets: targets,
            app: pointerActionRequest.app,
            excludingTargetIDs: []
        ))

        guard let matchedTarget else {
            let reason = pointerActionRequest.allowScreenshotPlanning ? "needs_screenshot_planner" : "target_not_found"
            let message = pointerActionRequest.allowScreenshotPlanning
                ? "No local target matched. Screenshot planning can be added here, but this endpoint currently refuses to guess raw coordinates."
                : "No local target matched the requested label or goal."
            return TipTourEnginePlanNextActionResult(
                ok: false,
                reason: reason,
                message: message,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: nil,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: targets
            )
        }

        let plannedStep = plannedActionStep(
            actionType: pointerActionRequest.actionType,
            target: matchedTarget
        )

        guard pointerActionRequest.execute else {
            return TipTourEnginePlanNextActionResult(
                ok: true,
                reason: nil,
                message: "Planned one grounded TipTour action.",
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: plannedStep,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: targets
            )
        }

        let executionResult = await executeGroundedActionOnce(
            goal: pointerActionRequest.goal,
            app: pointerActionRequest.app,
            requestedActionType: pointerActionRequest.actionType,
            initialTarget: matchedTarget,
            initialTargets: targets,
            requireStateChange: pointerActionRequest.validateStateChange
        )

        return TipTourEnginePlanNextActionResult(
            ok: executionResult.ok,
            reason: executionResult.reason,
            message: executionResult.message,
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            plannedStep: executionResult.attempts.first?.plannedStep ?? plannedStep,
            submission: executionResult.attempts.last?.submission,
            workflowOutcome: executionResult.attempts.last?.workflowOutcome,
            validation: executionResult.attempts.last?.validation,
            attempts: executionResult.attempts,
            repaired: executionResult.repaired,
            targets: executionResult.latestTargets
        )
    }

    func submitSingleActionWorkflowPlan(_ plan: WorkflowPlan) -> TipTourEngineSubmissionResult {
        guard isAutopilotEnabledProvider() else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "autopilot_disabled",
                message: "TipTour Autopilot is off. Turn it on before external harnesses can execute actions.",
                acceptedSteps: 0,
                ignoredSteps: plan.steps.count,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        guard isCuaActionDriverEnabledProvider() else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "action_driver_disabled",
                message: "CUA Driver is off. Turn it on before TipTour can execute desktop actions.",
                acceptedSteps: 0,
                ignoredSteps: plan.steps.count,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        activateRunningApplicationForWorkflowIfNeeded(plan.app)

        if let activePlan = WorkflowRunner.shared.activePlan {
            print("[Engine] superseding active plan \"\(activePlan.goal)\" with \"\(plan.goal)\"")
            WorkflowRunner.shared.stop()
        }

        let normalizedSteps = normalizeWorkflowSteps(
            plan.steps,
            plan.app ?? ""
        ).map { step in
            stepWithHarnessDefaults(step, planGoal: plan.goal, appName: plan.app)
        }
        guard let firstStep = normalizedSteps.first else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "empty_steps",
                message: "Workflow plan must contain at least one step.",
                acceptedSteps: 0,
                ignoredSteps: 0,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        if let invalidReason = invalidSingleActionReason(for: firstStep) {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: invalidReason,
                message: "Workflow step is missing the required payload for \(firstStep.type.rawValue).",
                acceptedSteps: 0,
                ignoredSteps: normalizedSteps.count,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        let singleActionPlan = WorkflowPlan(
            goal: plan.goal,
            app: plan.app,
            steps: [firstStep]
        )
        let ignoredSteps = max(0, normalizedSteps.count - 1)
        if ignoredSteps > 0 {
            print("[Engine] single-action mode: ignoring \(ignoredSteps) extra step(s)")
        }

        print("[Engine] accepted workflow plan \"\(singleActionPlan.goal)\" -> \(firstStep.label ?? firstStep.value ?? "<unlabeled>")")
        startWorkflowPlan(singleActionPlan)

        return TipTourEngineSubmissionResult(
            ok: true,
            reason: nil,
            message: "Accepted one TipTour action.",
            acceptedSteps: 1,
            ignoredSteps: ignoredSteps,
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    private func didRequestExplicitTarget(targetID: String?, targetMark: Int?) -> Bool {
        if let targetID = targetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetID.isEmpty {
            return true
        }
        return targetMark != nil
    }

    private func explicitTarget(
        requestedTargetID: String?,
        requestedTargetMark: Int?,
        targets: [LocalPerceptionTargetCache.SnapshotTarget]
    ) -> LocalPerceptionTargetCache.SnapshotTarget? {
        if let requestedTargetID = requestedTargetID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedTargetID.isEmpty,
           let target = targets.first(where: { $0.id == requestedTargetID }) {
            return target
        }

        if let requestedTargetMark,
           requestedTargetMark > 0,
           let target = targets.first(where: { $0.mark == requestedTargetMark }) {
            return target
        }

        return nil
    }

    private func bestTarget(
        requestedLabel: String?,
        goal: String,
        targets: [LocalPerceptionTargetCache.SnapshotTarget],
        app: String?,
        excludingTargetIDs: Set<String>
    ) -> LocalPerceptionTargetCache.SnapshotTarget? {
        let availableTargets = targetsForGoalContext(
            targets.filter { !excludingTargetIDs.contains($0.id) },
            goal: goal,
            app: app
        )
        guard !availableTargets.isEmpty else { return nil }

        let query = requestedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            return availableTargets
                .compactMap { target -> (target: LocalPerceptionTargetCache.SnapshotTarget, score: Double)? in
                    guard let score = labelMatchScore(query: query, label: target.label) else { return nil }
                    return (target, score + sourceScore(target.source) + min(target.confidence, 1.0))
                }
                .max { $0.score < $1.score }?
                .target
        }

        return availableTargets
            .compactMap { target -> (target: LocalPerceptionTargetCache.SnapshotTarget, score: Double)? in
                guard let score = labelMatchScore(query: goal, label: target.label) else { return nil }
                return (target, score + sourceScore(target.source) + min(target.confidence, 1.0))
            }
            .max { $0.score < $1.score }?
            .target
    }

    private func stepWithHarnessDefaults(
        _ step: WorkflowStep,
        planGoal: String,
        appName: String?
    ) -> WorkflowStep {
        switch step.type {
        case .type:
            guard (step.value?.isEmpty == false) || (step.label?.isEmpty == false) else {
                guard let inferredText = inferredTextToType(from: planGoal) else { return step }
                return replacingStepPayload(step, label: step.label, value: inferredText)
            }
            return step
        case .pressKey:
            guard step.label?.isEmpty != false else { return step }
            guard let inferredKey = inferredKeyToPress(from: planGoal, appName: appName) else { return step }
            return replacingStepPayload(step, label: inferredKey, value: step.value)
        case .keyboardShortcut:
            guard step.label?.isEmpty != false else { return step }
            guard let inferredShortcut = inferredKeyboardShortcut(from: planGoal) else { return step }
            return replacingStepPayload(step, label: inferredShortcut, value: step.value)
        default:
            return step
        }
    }

    private func invalidSingleActionReason(for step: WorkflowStep) -> String? {
        switch step.type {
        case .type:
            return ((step.value ?? step.label)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? nil
                : "type_text_missing"
        case .pressKey:
            return (step.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? nil
                : "press_key_missing"
        case .keyboardShortcut:
            return (step.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? nil
                : "keyboard_shortcut_missing"
        case .openApp, .openURL, .setValue:
            return ((step.value ?? step.label)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? nil
                : "\(step.type.rawValue)_payload_missing"
        default:
            return nil
        }
    }

    private func inferredTextToType(from goal: String) -> String? {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedGoal = trimmedGoal.lowercased()
        for prefix in ["type ", "enter ", "input ", "write "] {
            guard lowercasedGoal.hasPrefix(prefix) else { continue }
            let startIndex = trimmedGoal.index(trimmedGoal.startIndex, offsetBy: prefix.count)
            let inferredText = String(trimmedGoal[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return inferredText.isEmpty ? nil : inferredText
        }
        return nil
    }

    private func inferredKeyToPress(from goal: String, appName: String?) -> String? {
        let normalizedGoal = normalizedCommandText(goal)

        if let activeSkill = skillForAppHint(appName),
           let skillCommandAlias = activeSkill.commandAlias(for: goal),
           skillCommandAlias.type == .pressKey {
            return skillCommandAlias.label
        }

        if normalizedGoal.contains("confirm") || normalizedGoal.contains("apply") || normalizedGoal == "enter" {
            return "Return"
        }
        if normalizedGoal.contains("escape") || normalizedGoal.contains("cancel") {
            return "Escape"
        }

        return nil
    }

    private func inferredKeyboardShortcut(from goal: String) -> String? {
        switch normalizedCommandText(goal) {
        case "selectall":
            return "Cmd+A"
        case "copy":
            return "Cmd+C"
        case "paste":
            return "Cmd+V"
        case "cut":
            return "Cmd+X"
        case "undo":
            return "Cmd+Z"
        case "redo":
            return "Cmd+Shift+Z"
        default:
            return nil
        }
    }

    private func replacingStepPayload(
        _ step: WorkflowStep,
        label: String?,
        value: String?
    ) -> WorkflowStep {
        WorkflowStep(
            id: step.id,
            type: step.type,
            label: label,
            targetID: step.targetID,
            targetMark: step.targetMark,
            value: value,
            direction: step.direction,
            amount: step.amount,
            by: step.by,
            targetContext: step.targetContext,
            hint: step.hint,
            hintX: step.hintX,
            hintY: step.hintY,
            box2DNormalized: step.box2DNormalized,
            screenNumber: step.screenNumber
        )
    }

    private func targetsForGoalContext(
        _ targets: [LocalPerceptionTargetCache.SnapshotTarget],
        goal: String,
        app: String?
    ) -> [LocalPerceptionTargetCache.SnapshotTarget] {
        let normalizedGoal = normalizedCommandText(goal)
        let isChoosingFromMenu = normalizedGoal.contains("submenu")
            || normalizedGoal.contains("menuitem")
            || normalizedGoal.contains("dropdown")
            || normalizedGoal.contains("popover")
            || normalizedGoal.contains("frommenu")

        guard isChoosingFromMenu else { return targets }
        guard let activeSkill = skillForAppHint(app),
              let maximumNormalizedX = activeSkill.menuSelectionPreferredLeftRegionMaxX else {
            return targets
        }

        let filteredTargets = targets.filter { target in
            guard target.globalCenter.count >= 2,
                  target.displayFrame.count >= 4 else {
                return true
            }

            let centerX = target.globalCenter[0]
            let displayMinX = target.displayFrame[0]
            let displayMaxX = target.displayFrame[2]
            let displayWidth = max(1, displayMaxX - displayMinX)
            let normalizedX = (centerX - displayMinX) / displayWidth

            return normalizedX < maximumNormalizedX
        }

        return filteredTargets.isEmpty ? targets : filteredTargets
    }

    private func skillForAppHint(_ appName: String?) -> MarkdownAppSkill? {
        MarkdownAppSkillRegistry.shared.skill(applicationName: appName)
            ?? MarkdownAppSkillRegistry.shared.skill(for: NSWorkspace.shared.frontmostApplication)
    }

    private func normalizedCommandText(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func activateRequestedApplicationForPerceptionIfNeeded(_ applicationNameOrBundleIdentifier: String?) async {
        guard let applicationNameOrBundleIdentifier = applicationNameOrBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !applicationNameOrBundleIdentifier.isEmpty else {
            return
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           Self.application(frontmostApplication, matches: applicationNameOrBundleIdentifier) {
            return
        }

        let runningApplication = NSWorkspace.shared.runningApplications.first {
            Self.application($0, matches: applicationNameOrBundleIdentifier)
        }

        if let runningApplication {
            runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 260_000_000)
            return
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationNameOrBundleIdentifier) ??
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.commonBundleIdentifier(for: applicationNameOrBundleIdentifier) ?? "") else {
            print("[Engine] target app \"\(applicationNameOrBundleIdentifier)\" is not running and could not be found for perception activation")
            return
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let launchedApplication = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            launchedApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 520_000_000)
        } catch {
            print("[Engine] failed to activate \"\(applicationNameOrBundleIdentifier)\" before perception refresh: \(error.localizedDescription)")
        }
    }

    private static func application(_ runningApplication: NSRunningApplication, matches requestedNameOrBundleIdentifier: String) -> Bool {
        let normalizedRequestedValue = requestedNameOrBundleIdentifier.lowercased()
        return runningApplication.bundleIdentifier?.lowercased() == normalizedRequestedValue
            || runningApplication.localizedName?.lowercased() == normalizedRequestedValue
    }

    private func activateRunningApplicationForWorkflowIfNeeded(_ applicationNameOrBundleIdentifier: String?) {
        guard let applicationNameOrBundleIdentifier = applicationNameOrBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !applicationNameOrBundleIdentifier.isEmpty else {
            return
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           Self.application(frontmostApplication, matches: applicationNameOrBundleIdentifier) {
            return
        }

        let runningApplication = NSWorkspace.shared.runningApplications.first {
            Self.application($0, matches: applicationNameOrBundleIdentifier)
        }

        runningApplication?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private static func commonBundleIdentifier(for applicationName: String) -> String? {
        switch applicationName.lowercased() {
        case "blender":
            return "org.blenderfoundation.blender"
        case "chrome", "google chrome":
            return "com.google.Chrome"
        case "safari":
            return "com.apple.Safari"
        case "xcode":
            return "com.apple.dt.Xcode"
        case "terminal":
            return "com.apple.Terminal"
        default:
            return nil
        }
    }

    private func labelMatchScore(query: String, label: String) -> Double? {
        let queryWords = meaningfulWords(from: query)
        let labelWords = meaningfulWords(from: label)
        guard !queryWords.isEmpty, !labelWords.isEmpty else { return nil }

        let normalizedQuery = queryWords.joined(separator: " ")
        let normalizedLabel = labelWords.joined(separator: " ")
        if normalizedQuery == normalizedLabel { return 100 }
        if normalizedQuery.contains(normalizedLabel) || normalizedLabel.contains(normalizedQuery) {
            return 72
        }

        let sharedWords = Set(queryWords).intersection(Set(labelWords))
        guard !sharedWords.isEmpty else { return nil }
        return 36 + (Double(sharedWords.count) / Double(max(labelWords.count, 1)) * 28)
    }

    private func meaningfulWords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "this", "that", "button", "menu", "item",
            "click", "press", "choose", "select"
        ]
        let words = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopWords.contains($0) }
        return words.isEmpty
            ? text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            : words
    }

    private func sourceScore(_ source: String) -> Double {
        source == "ocr" ? 4 : 1
    }

    private struct GroundedActionExecutionResult {
        let ok: Bool
        let reason: String?
        let message: String?
        let attempts: [TipTourEngineActionAttempt]
        let repaired: Bool
        let latestTargets: [LocalPerceptionTargetCache.SnapshotTarget]
    }

    private func executeGroundedActionOnce(
        goal: String,
        app: String?,
        requestedActionType: WorkflowStep.StepType,
        initialTarget: LocalPerceptionTargetCache.SnapshotTarget,
        initialTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) async -> GroundedActionExecutionResult {
        let attempt = await executeGroundedActionAttempt(
            attemptNumber: 1,
            goal: goal,
            app: app,
            actionType: requestedActionType,
            target: initialTarget,
            targetsBeforeAttempt: initialTargets,
            requireStateChange: requireStateChange
        )
        recordActionAttempt(attempt)

        if attempt.submission.ok,
           attempt.workflowOutcome.status == "completed",
           (!attempt.validation.requiredStateChange || attempt.validation.stateChanged) {
            return GroundedActionExecutionResult(
                ok: true,
                reason: nil,
                message: "Executed one grounded TipTour action.",
                attempts: [attempt],
                repaired: false,
                latestTargets: LocalPerceptionTargetCache.shared.currentTargets()
            )
        }

        let reason: String
        if !attempt.submission.ok {
            reason = attempt.submission.reason ?? "submission_failed"
        } else if attempt.workflowOutcome.status != "completed" {
            reason = attempt.workflowOutcome.reason ?? attempt.workflowOutcome.status
        } else if attempt.validation.requiredStateChange,
                  !attempt.validation.stateChanged {
            reason = "state_unchanged"
        } else {
            reason = "grounded_action_failed"
        }

        return GroundedActionExecutionResult(
            ok: false,
            reason: reason,
            message: "TipTour ran one grounded action but could not validate it.",
            attempts: [attempt],
            repaired: false,
            latestTargets: LocalPerceptionTargetCache.shared.currentTargets()
        )
    }

    private func executeGroundedActionAttempt(
        attemptNumber: Int,
        goal: String,
        app: String?,
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget,
        targetsBeforeAttempt: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) async -> TipTourEngineActionAttempt {
        let step = workflowStep(
            actionType: actionType,
            target: target,
            id: "harness_planned_step_\(attemptNumber)"
        )
        let plannedStep = plannedActionStep(
            actionType: actionType,
            target: target
        )
        let submission = submitSingleActionWorkflowPlan(
            WorkflowPlan(
                goal: goal,
                app: app,
                steps: [step]
            )
        )

        let workflowOutcome: TipTourEngineWorkflowOutcome
        if submission.ok {
            workflowOutcome = await waitForWorkflowSettlement()
        } else {
            workflowOutcome = TipTourEngineWorkflowOutcome(
                status: "not_started",
                reason: submission.reason,
                message: submission.message,
                waitMs: 0
            )
        }

        await refreshLocalPerception("harness post-action validation")
        let targetsAfterAttempt = LocalPerceptionTargetCache.shared.currentTargets()
        let validation = validateTargetSetChange(
            beforeTargets: targetsBeforeAttempt,
            afterTargets: targetsAfterAttempt,
            requireStateChange: requireStateChange
        )

        return TipTourEngineActionAttempt(
            attemptNumber: attemptNumber,
            timestamp: Self.iso8601Formatter.string(from: Date()),
            target: target,
            plannedStep: plannedStep,
            submission: submission,
            workflowOutcome: workflowOutcome,
            validation: validation
        )
    }

    private func workflowStep(
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget,
        id: String
    ) -> WorkflowStep {
        WorkflowStep(
            id: id,
            type: actionType,
            label: target.label,
            targetID: target.id,
            targetMark: target.mark,
            value: nil,
            direction: nil,
            amount: nil,
            by: nil,
            targetContext: .visibleElement,
            hint: "Use local perception target \"\(target.label)\"",
            hintX: nil,
            hintY: nil,
            box2DNormalized: target.normalizedBox2D,
            screenNumber: nil
        )
    }

    private func plannedActionStep(
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget
    ) -> TipTourEnginePlannedActionStep {
        TipTourEnginePlannedActionStep(
            type: actionType.rawValue,
            label: target.label,
            targetID: target.id,
            targetMark: target.mark,
            hint: "Use local perception target \"\(target.label)\"",
            box2D: target.normalizedBox2D,
            matchedSource: target.source,
            matchedConfidence: target.confidence
        )
    }

    private func waitForWorkflowSettlement() async -> TipTourEngineWorkflowOutcome {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(workflowSettlementTimeoutSeconds)

        while Date() < deadline {
            if let pausedReason = WorkflowRunner.shared.pausedReason {
                return TipTourEngineWorkflowOutcome(
                    status: "paused",
                    reason: "workflow_paused",
                    message: pausedReason.humanReadable,
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            if let failedLabel = WorkflowRunner.shared.currentStepResolutionFailureLabel {
                return TipTourEngineWorkflowOutcome(
                    status: "resolution_failed",
                    reason: "target_not_resolved",
                    message: "Could not resolve \"\(failedLabel)\" within WorkflowRunner's retry budget.",
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            if WorkflowRunner.shared.activePlan == nil {
                return TipTourEngineWorkflowOutcome(
                    status: "completed",
                    reason: nil,
                    message: "WorkflowRunner completed the single action.",
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return TipTourEngineWorkflowOutcome(
            status: "timed_out",
            reason: "workflow_settlement_timeout",
            message: "WorkflowRunner did not complete or pause within \(workflowSettlementTimeoutSeconds)s.",
            waitMs: Self.elapsedMilliseconds(since: startedAt)
        )
    }

    private func validateTargetSetChange(
        beforeTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        afterTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) -> TipTourEngineActionValidation {
        TipTourEngineActionValidation(
            stateChanged: targetSetSignature(beforeTargets) != targetSetSignature(afterTargets),
            requiredStateChange: requireStateChange,
            beforeTargetCount: beforeTargets.count,
            afterTargetCount: afterTargets.count
        )
    }

    private func targetSetSignature(_ targets: [LocalPerceptionTargetCache.SnapshotTarget]) -> String {
        targets
            .map { target in
                let quantizedBox = target.normalizedBox2D
                    .map { coordinate in
                        Int((Double(coordinate) / 10.0).rounded()) * 10
                    }
                    .map(String.init)
                    .joined(separator: ",")
                return "\(target.source):\(target.label.lowercased()):\(quantizedBox)"
            }
            .sorted()
            .joined(separator: "|")
    }

    private func recordActionAttempt(_ attempt: TipTourEngineActionAttempt) {
        recentActionAttempts.append(attempt)
        if recentActionAttempts.count > maximumRecentActionAttempts {
            recentActionAttempts.removeFirst(recentActionAttempts.count - maximumRecentActionAttempts)
        }
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        Int(Date().timeIntervalSince(startDate) * 1000)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
