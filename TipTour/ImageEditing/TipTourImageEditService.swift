//
//  TipTourImageEditService.swift
//  TipTour
//
//  File-aware image edit preparation for external agents. TipTour resolves
//  the user's highlighted image source, captures a highlighted screenshot
//  reference, and can optionally call Gemini image editing with local keys.
//

import AppKit
import ApplicationServices
import Foundation
import ImageIO

struct TipTourImageEditRequest: Decodable {
    let prompt: String?
    let instruction: String?
    let goal: String?
    let source: String?
    let sourceFilePath: String?
    let source_file_path: String?
    let execute: Bool?
    let provider: String?
    let model: String?
    let outputMode: String?
    let output_mode: String?
    let openResult: Bool?
    let open_result: Bool?
    let traceID: String?
    let trace_id: String?

    var normalizedPrompt: String? {
        firstNonEmpty(prompt, instruction, goal)
    }

    var normalizedSourceFilePath: String? {
        firstNonEmpty(sourceFilePath, source_file_path)
    }

    var normalizedTraceID: String? {
        firstNonEmpty(traceID, trace_id)
    }

    var normalizedModel: String {
        firstNonEmpty(model) ?? "gemini-2.5-flash-image"
    }

    var normalizedProvider: String {
        firstNonEmpty(provider) ?? "gemini"
    }

    var normalizedOutputMode: String {
        firstNonEmpty(outputMode, output_mode) ?? "copy"
    }

    var shouldExecute: Bool {
        execute ?? false
    }

    var shouldOpenResult: Bool {
        openResult ?? open_result ?? true
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct TipTourImageEditResponse: Encodable {
    let ok: Bool
    let traceID: String
    let reason: String?
    let message: String
    let prompt: String
    let source: TipTourHighlightSourceResolution
    let artifacts: TipTourImageEditArtifacts?
    let execution: TipTourImageEditExecution?

    private enum CodingKeys: String, CodingKey {
        case ok
        case traceID = "trace_id"
        case reason
        case message
        case prompt
        case source
        case artifacts
        case execution
    }
}

struct TipTourImageEditArtifacts: Encodable {
    let directoryPath: String
    let requestJSONPath: String
    let sourceScreenshotPath: String?
    let highlightedScreenshotPath: String?
    let highlightCropPath: String?
    let originalReferencePath: String?
    let highlightScreenRect: [Double]?
    let highlightedScreenshotPixelRect: [Int]?

    private enum CodingKeys: String, CodingKey {
        case directoryPath = "directory_path"
        case requestJSONPath = "request_json_path"
        case sourceScreenshotPath = "source_screenshot_path"
        case highlightedScreenshotPath = "highlighted_screenshot_path"
        case highlightCropPath = "highlight_crop_path"
        case originalReferencePath = "original_reference_path"
        case highlightScreenRect = "highlight_screen_rect"
        case highlightedScreenshotPixelRect = "highlighted_screenshot_pixel_rect"
    }
}

struct TipTourImageEditExecution: Encodable {
    let attempted: Bool
    let ok: Bool
    let provider: String
    let model: String
    let reason: String?
    let message: String
    let outputPath: String?
    let elapsedMs: Int?
    let outputLooksUnchanged: Bool?
    let visualDifferenceScore: Double?

    init(
        attempted: Bool,
        ok: Bool,
        provider: String,
        model: String,
        reason: String?,
        message: String,
        outputPath: String?,
        elapsedMs: Int?,
        outputLooksUnchanged: Bool? = nil,
        visualDifferenceScore: Double? = nil
    ) {
        self.attempted = attempted
        self.ok = ok
        self.provider = provider
        self.model = model
        self.reason = reason
        self.message = message
        self.outputPath = outputPath
        self.elapsedMs = elapsedMs
        self.outputLooksUnchanged = outputLooksUnchanged
        self.visualDifferenceScore = visualDifferenceScore
    }

    private enum CodingKeys: String, CodingKey {
        case attempted
        case ok
        case provider
        case model
        case reason
        case message
        case outputPath = "output_path"
        case elapsedMs = "elapsed_ms"
        case outputLooksUnchanged = "output_looks_unchanged"
        case visualDifferenceScore = "visual_difference_score"
    }
}

@MainActor
final class TipTourImageEditService {
    private let currentFocusHighlightContextProvider: () -> FocusHighlightContext?
    private let currentTargetApplicationProvider: () -> NSRunningApplication?
    private let latestScreenCaptureProvider: () -> CompanionScreenCapture?
    private let isScreenshotStreamingEnabledProvider: () -> Bool

    init(
        currentFocusHighlightContextProvider: @escaping () -> FocusHighlightContext?,
        currentTargetApplicationProvider: @escaping () -> NSRunningApplication? = { nil },
        latestScreenCaptureProvider: @escaping () -> CompanionScreenCapture? = { nil },
        isScreenshotStreamingEnabledProvider: @escaping () -> Bool
    ) {
        self.currentFocusHighlightContextProvider = currentFocusHighlightContextProvider
        self.currentTargetApplicationProvider = currentTargetApplicationProvider
        self.latestScreenCaptureProvider = latestScreenCaptureProvider
        self.isScreenshotStreamingEnabledProvider = isScreenshotStreamingEnabledProvider
    }

    func prepareOrExecute(_ request: TipTourImageEditRequest) async -> TipTourImageEditResponse {
        let traceID = request.normalizedTraceID ?? TipTourActionTrace.makeID(source: "image")
        guard let prompt = request.normalizedPrompt else {
            return TipTourImageEditResponse(
                ok: false,
                traceID: traceID,
                reason: "missing_prompt",
                message: "POST /v1/image-edit requires prompt, instruction, or goal.",
                prompt: "",
                source: unresolvedSource(reason: "missing_prompt", message: "No edit prompt was provided."),
                artifacts: nil,
                execution: nil
            )
        }

        let context = currentFocusHighlightContextProvider()
        let sourceResolution = TipTourHighlightSourceResolver.resolve(
            explicitFilePath: request.normalizedSourceFilePath,
            highlightContext: context,
            fallbackApplication: currentTargetApplicationProvider()
        )

        guard let artifacts = await createArtifacts(
            traceID: traceID,
            prompt: prompt,
            sourceResolution: sourceResolution,
            highlightContext: context,
            request: request
        ) else {
            return TipTourImageEditResponse(
                ok: false,
                traceID: traceID,
                reason: "artifact_creation_failed",
                message: "Could not create local image edit artifacts.",
                prompt: prompt,
                source: sourceResolution,
                artifacts: nil,
                execution: nil
            )
        }

        guard request.shouldExecute else {
            return TipTourImageEditResponse(
                ok: true,
                traceID: traceID,
                reason: nil,
                message: "Prepared a file-aware image edit job. Set execute=true to call the image model.",
                prompt: prompt,
                source: sourceResolution,
                artifacts: artifacts,
                execution: TipTourImageEditExecution(
                    attempted: false,
                    ok: false,
                    provider: request.normalizedProvider,
                    model: request.normalizedModel,
                    reason: "not_requested",
                    message: "Execution was not requested.",
                    outputPath: nil,
                    elapsedMs: nil
                )
            )
        }

        let execution = await executeImageEdit(
            prompt: prompt,
            request: request,
            sourceResolution: sourceResolution,
            artifacts: artifacts
        )

        return TipTourImageEditResponse(
            ok: execution.ok,
            traceID: traceID,
            reason: execution.reason,
            message: execution.message,
            prompt: prompt,
            source: sourceResolution,
            artifacts: artifacts,
            execution: execution
        )
    }

    private func createArtifacts(
        traceID: String,
        prompt: String,
        sourceResolution: TipTourHighlightSourceResolution,
        highlightContext: FocusHighlightContext?,
        request: TipTourImageEditRequest
    ) async -> TipTourImageEditArtifacts? {
        do {
            let directoryURL = try artifactDirectory(traceID: traceID)
            let screenshotArtifact = try await highlightedScreenshotArtifact(
                highlightContext: highlightContext,
                directoryURL: directoryURL
            )
            let originalReferenceURL = try copyOriginalReferenceIfAvailable(
                sourceResolution: sourceResolution,
                directoryURL: directoryURL
            )
            let requestJSONURL = directoryURL.appendingPathComponent("request.json")
            let requestJSON = artifactRequestJSON(
                traceID: traceID,
                prompt: prompt,
                sourceResolution: sourceResolution,
                request: request,
                screenshotArtifact: screenshotArtifact,
                originalReferenceURL: originalReferenceURL
            )
            let requestJSONData = try JSONSerialization.data(
                withJSONObject: requestJSON,
                options: [.prettyPrinted, .sortedKeys]
            )
            try requestJSONData.write(to: requestJSONURL, options: .atomic)

            return TipTourImageEditArtifacts(
                directoryPath: directoryURL.path,
                requestJSONPath: requestJSONURL.path,
                sourceScreenshotPath: screenshotArtifact?.sourceScreenshotURL.path,
                highlightedScreenshotPath: screenshotArtifact?.highlightedScreenshotURL.path,
                highlightCropPath: screenshotArtifact?.highlightCropURL?.path,
                originalReferencePath: originalReferenceURL?.path,
                highlightScreenRect: highlightContext.map(Self.rectArray),
                highlightedScreenshotPixelRect: screenshotArtifact?.pixelRectArray
            )
        } catch {
            return nil
        }
    }

    private func executeImageEdit(
        prompt: String,
        request: TipTourImageEditRequest,
        sourceResolution: TipTourHighlightSourceResolution,
        artifacts: TipTourImageEditArtifacts
    ) async -> TipTourImageEditExecution {
        let provider = request.normalizedProvider.lowercased()
        let model = request.normalizedModel
        guard provider == "gemini" || provider == "nano_banana" || provider == "nanobanana" else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "unsupported_provider",
                message: "Only Gemini/Nano Banana execution is wired in this phase.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        guard request.normalizedOutputMode == "copy" else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "replace_not_supported",
                message: "TipTour image edit currently saves a copy only. Replacing originals needs explicit confirmation UI.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        guard isScreenshotStreamingEnabledProvider() else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "remote_visual_context_disabled",
                message: "Screenshots is off. Turn it on before sending image content to a remote image-edit model.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        guard let apiKey = KeychainStore.geminiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "missing_gemini_key",
                message: "Gemini API key is missing from TipTour Settings.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        let isLocalImageSource = sourceResolution.contentCategory == "image"
        let isScreenshotOnlyVisualSource = sourceResolution.contentCategory == "visual"
            && sourceResolution.kind == "screenshot_only"
        guard isLocalImageSource || isScreenshotOnlyVisualSource else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "source_not_image",
                message: "The highlighted source resolved to \(sourceResolution.contentCategory), not an editable image or screenshot.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        guard let resolvedInputImage = Self.resolvedInputImage(
            sourceResolution: sourceResolution,
            artifacts: artifacts
        ) else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "source_file_unavailable",
                message: "A readable local source image or screenshot is required for model execution.",
                outputPath: nil,
                elapsedMs: nil
            )
        }
        guard let providerInputImage = Self.providerInputImageData(inputImage: resolvedInputImage) else {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "unsupported_source_image_format",
                message: "TipTour could not decode the source image into a provider-safe PNG or JPEG upload.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        let highlightedScreenshotData = artifacts.highlightedScreenshotPath.flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0))
        }
        let highlightCropData = artifacts.highlightCropPath.flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0))
        }
        let promptRequiresHighlightReference = prompt.localizedCaseInsensitiveContains("highlight")
            || prompt.localizedCaseInsensitiveContains("this area")
            || prompt.localizedCaseInsensitiveContains("selected area")
        if promptRequiresHighlightReference,
           highlightedScreenshotData == nil,
           highlightCropData == nil {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "highlight_reference_unavailable",
                message: "TipTour resolved the source image, but could not capture the highlighted screen reference. Paint the highlight again and retry.",
                outputPath: nil,
                elapsedMs: nil
            )
        }

        let highlightedScreenshotMimeType = artifacts.highlightedScreenshotPath.map(Self.mimeType(forPath:))
            ?? "image/jpeg"
        let highlightCropMimeType = artifacts.highlightCropPath.map(Self.mimeType(forPath:))
            ?? "image/jpeg"
        let editPrompt = """
        Edit the source image according to the user request and return the full edited image.

        User request: \(prompt)

        The first image is the source image to edit. It may be a local image file or a screenshot of the highlighted app.
        If a second image is provided, it is a screenshot reference from the user's screen with a red highlighted rectangle showing the selected area.
        If a third image is provided, it is a close crop of that highlighted area.

        Modify the corresponding selected area in the source image. Preserve unrelated parts of the image as much as possible. Do not return the source image unchanged when the request asks for an edit.
        """

        let startDate = Date()
        do {
            let editedImage = try await GeminiImageEditClient(apiKey: apiKey).editImage(
                model: model,
                prompt: editPrompt,
                originalImageData: providerInputImage.data,
                originalMimeType: providerInputImage.mimeType,
                highlightedScreenshotData: highlightedScreenshotData,
                highlightedScreenshotMimeType: highlightedScreenshotMimeType,
                highlightCropData: highlightCropData,
                highlightCropMimeType: highlightCropMimeType
            )
            let outputExtension = Self.fileExtension(forMimeType: editedImage.mimeType)
            let outputURL = URL(fileURLWithPath: artifacts.directoryPath)
                .appendingPathComponent("edited-output.\(outputExtension)")
            try editedImage.data.write(to: outputURL, options: .atomic)
            if request.shouldOpenResult {
                Self.openEditedOutput(outputURL)
            }
            let visualDifferenceScore = Self.visualDifferenceScore(
                originalImageData: resolvedInputImage.data,
                editedImageData: editedImage.data
            )
            let outputLooksUnchanged = visualDifferenceScore.map { $0 < 0.012 }
            let message = outputLooksUnchanged == true
                ? "Image edit completed and saved as a copy, but the output looks very similar to the original."
                : "Image edit completed and saved as a copy."

            return TipTourImageEditExecution(
                attempted: true,
                ok: true,
                provider: request.normalizedProvider,
                model: model,
                reason: nil,
                message: message,
                outputPath: outputURL.path,
                elapsedMs: Int(Date().timeIntervalSince(startDate) * 1000),
                outputLooksUnchanged: outputLooksUnchanged,
                visualDifferenceScore: visualDifferenceScore
            )
        } catch {
            return TipTourImageEditExecution(
                attempted: true,
                ok: false,
                provider: request.normalizedProvider,
                model: model,
                reason: "provider_request_failed",
                message: error.localizedDescription,
                outputPath: nil,
                elapsedMs: Int(Date().timeIntervalSince(startDate) * 1000)
            )
        }
    }

    private func highlightedScreenshotArtifact(
        highlightContext: FocusHighlightContext?,
        directoryURL: URL
    ) async throws -> HighlightedScreenshotArtifact? {
        guard let highlightContext else { return nil }
        if let latestCapture = latestScreenCaptureProvider(),
           let artifact = try screenshotArtifact(
            baseImage: Self.cgImage(fromImageData: latestCapture.imageData),
            highlightRect: highlightContext.globalAppKitBoundingRect,
            displayFrame: latestCapture.displayFrame,
            screenshotWidthInPixels: latestCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: latestCapture.screenshotHeightInPixels,
            directoryURL: directoryURL
           ) {
            return artifact
        }

        let captures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
        if let capture = Self.bestCapture(for: highlightContext, captures: captures),
           let artifact = try screenshotArtifact(
            baseImage: Self.cgImage(fromImageData: capture.imageData),
            highlightRect: highlightContext.globalAppKitBoundingRect,
            displayFrame: capture.displayFrame,
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels,
            directoryURL: directoryURL
           ) {
            return artifact
        }

        if let rawCapture = try? await CompanionScreenCaptureUtility.captureCursorScreenAsCGImage() {
            return try screenshotArtifact(
                baseImage: rawCapture.image,
                highlightRect: highlightContext.globalAppKitBoundingRect,
                displayFrame: rawCapture.displayFrame,
                screenshotWidthInPixels: rawCapture.image.width,
                screenshotHeightInPixels: rawCapture.image.height,
                directoryURL: directoryURL
            )
        }

        return nil
    }

    private func screenshotArtifact(
        baseImage: CGImage?,
        highlightRect: CGRect,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        directoryURL: URL
    ) throws -> HighlightedScreenshotArtifact? {
        let pixelRect = Self.pixelRect(
            for: highlightRect,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
        guard let baseImage else {
            return nil
        }
        guard let highlightedData = Self.jpegDataWithHighlight(
            baseImage: baseImage,
            pixelRect: pixelRect
        ) else {
            return nil
        }

        let sourceScreenshotURL = directoryURL.appendingPathComponent("source-screen.jpg")
        guard let sourceScreenshotData = Self.jpegData(from: baseImage, compression: 0.92) else {
            return nil
        }
        try sourceScreenshotData.write(to: sourceScreenshotURL, options: .atomic)

        let highlightedScreenshotURL = directoryURL.appendingPathComponent("highlighted-screen.jpg")
        try highlightedData.write(to: highlightedScreenshotURL, options: .atomic)

        let highlightCropURL: URL?
        if let cropData = Self.cropJPEGData(
            baseImage: baseImage,
            pixelRect: pixelRect
        ) {
            let cropURL = directoryURL.appendingPathComponent("highlight-crop.jpg")
            try cropData.write(to: cropURL, options: .atomic)
            highlightCropURL = cropURL
        } else {
            highlightCropURL = nil
        }

        return HighlightedScreenshotArtifact(
            sourceScreenshotURL: sourceScreenshotURL,
            highlightedScreenshotURL: highlightedScreenshotURL,
            highlightCropURL: highlightCropURL,
            pixelRectArray: [
                Int(pixelRect.minX),
                Int(pixelRect.minY),
                Int(pixelRect.width),
                Int(pixelRect.height)
            ]
        )
    }

    private func copyOriginalReferenceIfAvailable(
        sourceResolution: TipTourHighlightSourceResolution,
        directoryURL: URL
    ) throws -> URL? {
        guard let filePath = sourceResolution.filePath else { return nil }
        let sourceURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let extensionText = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let targetURL = directoryURL.appendingPathComponent("original-reference.\(extensionText)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    private func artifactDirectory(traceID: String) throws -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let safeTraceID = traceID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directoryURL = applicationSupportURL
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("image-edits", isDirectory: true)
            .appendingPathComponent(safeTraceID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func artifactRequestJSON(
        traceID: String,
        prompt: String,
        sourceResolution: TipTourHighlightSourceResolution,
        request: TipTourImageEditRequest,
        screenshotArtifact: HighlightedScreenshotArtifact?,
        originalReferenceURL: URL?
    ) -> [String: Any] {
        var source: [String: Any] = [
            "ok": sourceResolution.ok,
            "kind": sourceResolution.kind,
            "source": sourceResolution.source,
            "confidence": sourceResolution.confidence
        ]
        source["file_path"] = sourceResolution.filePath
        source["source_url"] = sourceResolution.sourceURL
        source["app_name"] = sourceResolution.appName
        source["bundle_identifier"] = sourceResolution.bundleIdentifier
        source["window_title"] = sourceResolution.windowTitle
        source["content_category"] = sourceResolution.contentCategory
        source["file_extension"] = sourceResolution.fileExtension
        source["mime_type"] = sourceResolution.mimeType
        source["highlight_screen_rect"] = sourceResolution.highlightScreenRect
        source["reason"] = sourceResolution.reason
        source["message"] = sourceResolution.message

        var artifacts: [String: Any] = [:]
        artifacts["original_reference_path"] = originalReferenceURL?.path
        artifacts["source_screenshot_path"] = screenshotArtifact?.sourceScreenshotURL.path
        artifacts["highlighted_screenshot_path"] = screenshotArtifact?.highlightedScreenshotURL.path
        artifacts["highlight_crop_path"] = screenshotArtifact?.highlightCropURL?.path
        artifacts["highlighted_screenshot_pixel_rect"] = screenshotArtifact?.pixelRectArray

        return [
            "trace_id": traceID,
            "prompt": prompt,
            "provider": request.normalizedProvider,
            "model": request.normalizedModel,
            "execute": request.shouldExecute,
            "output_mode": request.normalizedOutputMode,
            "source": source.compactMapValues { $0 },
            "artifacts": artifacts.compactMapValues { $0 }
        ]
    }

    private func unresolvedSource(reason: String, message: String) -> TipTourHighlightSourceResolution {
        TipTourHighlightSourceResolution(
            ok: false,
            kind: "unresolved",
            source: "none",
            filePath: nil,
            sourceURL: nil,
            appName: nil,
            bundleIdentifier: nil,
            processIdentifier: nil,
            windowTitle: nil,
            confidence: 0,
            reason: reason,
            message: message,
            contentCategory: "unknown",
            fileExtension: nil,
            mimeType: nil,
            selectedText: nil,
            highlightScreenRect: nil,
            tools: []
        )
    }

    private static func pixelRect(
        for globalRect: CGRect,
        in capture: CompanionScreenCapture
    ) -> CGRect {
        pixelRect(
            for: globalRect,
            displayFrame: capture.displayFrame,
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels
        )
    }

    private static func pixelRect(
        for globalRect: CGRect,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGRect {
        let intersection = globalRect.intersection(displayFrame)
        let safeIntersection = intersection.isNull ? globalRect : intersection
        let xScale = CGFloat(screenshotWidthInPixels) / max(1, displayFrame.width)
        let yScale = CGFloat(screenshotHeightInPixels) / max(1, displayFrame.height)

        let localMinX = safeIntersection.minX - displayFrame.minX
        let localTopY = displayFrame.maxY - safeIntersection.maxY
        let width = safeIntersection.width * xScale
        let height = safeIntersection.height * yScale

        let x = max(0, min(CGFloat(screenshotWidthInPixels) - 1, localMinX * xScale))
        let y = max(0, min(CGFloat(screenshotHeightInPixels) - 1, localTopY * yScale))
        let clampedWidth = max(1, min(CGFloat(screenshotWidthInPixels) - x, width))
        let clampedHeight = max(1, min(CGFloat(screenshotHeightInPixels) - y, height))
        return CGRect(x: x, y: y, width: clampedWidth, height: clampedHeight).integral
    }

    private static func bestCapture(
        for highlightContext: FocusHighlightContext,
        captures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        guard !captures.isEmpty else { return nil }
        let highlightRect = highlightContext.globalAppKitBoundingRect
        let highlightCenter = highlightContext.center

        return captures.max { lhs, rhs in
            let lhsOverlap = overlapArea(highlightRect, lhs.displayFrame)
            let rhsOverlap = overlapArea(highlightRect, rhs.displayFrame)
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            if lhs.isCursorScreen != rhs.isCursorScreen { return !lhs.isCursorScreen }
            return distanceSquared(highlightCenter, center(of: lhs.displayFrame))
                > distanceSquared(highlightCenter, center(of: rhs.displayFrame))
        }
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func overlapArea(_ firstRect: CGRect, _ secondRect: CGRect) -> CGFloat {
        let intersection = firstRect.intersection(secondRect)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func distanceSquared(_ firstPoint: CGPoint, _ secondPoint: CGPoint) -> CGFloat {
        let dx = firstPoint.x - secondPoint.x
        let dy = firstPoint.y - secondPoint.y
        return dx * dx + dy * dy
    }

    private static func jpegDataWithHighlight(
        baseImage: CGImage,
        pixelRect: CGRect
    ) -> Data? {
        let width = baseImage.width
        let height = baseImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawingRect = CGRect(
            x: pixelRect.minX,
            y: CGFloat(height) - pixelRect.maxY,
            width: pixelRect.width,
            height: pixelRect.height
        )
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
        context.fill(drawingRect)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(6)
        context.stroke(drawingRect)

        guard let outputImage = context.makeImage() else { return nil }
        return jpegData(from: outputImage, compression: 0.92)
    }

    private static func cropJPEGData(
        baseImage: CGImage,
        pixelRect: CGRect
    ) -> Data? {
        guard let croppedImage = baseImage.cropping(to: pixelRect) else {
            return nil
        }
        return jpegData(from: croppedImage, compression: 0.92)
    }

    private static func jpegData(from image: CGImage, compression: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func cgImage(fromImageData imageData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    private static func rectArray(_ context: FocusHighlightContext) -> [Double] {
        let rect = context.globalAppKitBoundingRect
        return [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    private static func mimeType(forPath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "tif", "tiff": return "image/tiff"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    private static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/gif": return "gif"
        default: return "png"
        }
    }

    private static func resolvedInputImage(
        sourceResolution: TipTourHighlightSourceResolution,
        artifacts: TipTourImageEditArtifacts
    ) -> (data: Data, mimeType: String, path: String?)? {
        if let originalPath = sourceResolution.filePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: originalPath)) {
            return (data, mimeType(forPath: originalPath), originalPath)
        }
        if let screenshotPath = artifacts.sourceScreenshotPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: screenshotPath)) {
            return (data, "image/jpeg", screenshotPath)
        }
        return nil
    }

    private static func providerInputImageData(
        inputImage: (data: Data, mimeType: String, path: String?)
    ) -> (data: Data, mimeType: String)? {
        let mimeType = inputImage.mimeType
        switch mimeType {
        case "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif":
            return (inputImage.data, mimeType)
        default:
            guard let image = NSImage(data: inputImage.data),
                  let pngData = pngData(from: image) else {
                return nil
            }
            return (pngData, "image/png")
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func openEditedOutput(_ outputURL: URL) {
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if FileManager.default.fileExists(atPath: previewURL.path) {
            NSWorkspace.shared.open(
                [outputURL],
                withApplicationAt: previewURL,
                configuration: configuration
            ) { _, error in
                if error != nil {
                    NSWorkspace.shared.open(outputURL)
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            }
        } else {
            NSWorkspace.shared.open(outputURL)
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private static func visualDifferenceScore(
        originalImageData: Data,
        editedImageData: Data
    ) -> Double? {
        guard let originalVector = luminanceVector(from: originalImageData),
              let editedVector = luminanceVector(from: editedImageData),
              originalVector.count == editedVector.count,
              !originalVector.isEmpty else {
            return nil
        }
        let difference = zip(originalVector, editedVector).reduce(0.0) { partialResult, pair in
            partialResult + abs(pair.0 - pair.1)
        }
        return difference / Double(originalVector.count)
    }

    private static func luminanceVector(from imageData: Data, sideLength: Int = 24) -> [Double]? {
        guard let image = NSImage(data: imageData) else { return nil }
        let thumbnail = NSImage(size: CGSize(width: sideLength, height: sideLength))
        thumbnail.lockFocus()
        image.draw(
            in: CGRect(x: 0, y: 0, width: sideLength, height: sideLength),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        var values: [Double] = []
        values.reserveCapacity(sideLength * sideLength)
        for y in 0..<sideLength {
            for x in 0..<sideLength {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    values.append(0)
                    continue
                }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                values.append(Double(luminance))
            }
        }
        return values
    }
}

private struct HighlightedScreenshotArtifact {
    let sourceScreenshotURL: URL
    let highlightedScreenshotURL: URL
    let highlightCropURL: URL?
    let pixelRectArray: [Int]
}

private struct GeminiImageEditClient {
    struct EditedImage {
        let data: Data
        let mimeType: String
    }

    let apiKey: String

    func editImage(
        model: String,
        prompt: String,
        originalImageData: Data,
        originalMimeType: String,
        highlightedScreenshotData: Data?,
        highlightedScreenshotMimeType: String,
        highlightCropData: Data?,
        highlightCropMimeType: String
    ) async throws -> EditedImage {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = [
            [
                "text": """
                \(prompt)

                Image 1 is the source image to edit. It may be a local image file or a screenshot.
                """
            ],
            [
                "inline_data": [
                    "mime_type": originalMimeType,
                    "data": originalImageData.base64EncodedString()
                ]
            ]
        ]
        if let highlightedScreenshotData {
            parts.append([
                "text": "Image 2 is the user's screen reference. The red rectangle marks the area to edit."
            ])
            parts.append([
                "inline_data": [
                    "mime_type": highlightedScreenshotMimeType,
                    "data": highlightedScreenshotData.base64EncodedString()
                ]
            ])
        }
        if let highlightCropData {
            parts.append([
                "text": "Image 3 is a close crop of the highlighted area."
            ])
            parts.append([
                "inline_data": [
                    "mime_type": highlightCropMimeType,
                    "data": highlightCropData.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                ["parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GeminiImageEditClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Gemini image edit returned a non-HTTP response."]
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let preview = String(data: data.prefix(700), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GeminiImageEditClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Gemini image edit failed with HTTP \(httpResponse.statusCode): \(preview)"]
            )
        }
        guard let imagePart = Self.firstInlineImagePart(in: data),
              let imageData = Data(base64Encoded: imagePart.data) else {
            let preview = String(data: data.prefix(700), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GeminiImageEditClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Gemini image edit did not return image data. Response preview: \(preview)"]
            )
        }
        return EditedImage(data: imageData, mimeType: imagePart.mimeType)
    }

    private static func firstInlineImagePart(in data: Data) -> (data: String, mimeType: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findInlineImagePart(in: object)
    }

    private static func findInlineImagePart(in object: Any) -> (data: String, mimeType: String)? {
        if let dictionary = object as? [String: Any] {
            for key in ["inlineData", "inline_data"] {
                if let inlineData = dictionary[key] as? [String: Any],
                   let data = inlineData["data"] as? String {
                    let mimeType = (inlineData["mimeType"] as? String)
                        ?? (inlineData["mime_type"] as? String)
                        ?? "image/png"
                    if mimeType.lowercased().hasPrefix("image/") {
                        return (data, mimeType)
                    }
                }
            }
            for value in dictionary.values {
                if let match = findInlineImagePart(in: value) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findInlineImagePart(in: value) {
                    return match
                }
            }
        }
        return nil
    }
}
