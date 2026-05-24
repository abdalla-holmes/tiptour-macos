//
//  OmniParserHarnessClient.swift
//  TipTour
//
//  Optional local screen-parser sidecar contract. TipTour keeps the native
//  YOLO/OCR path and merges OmniParser results when this harness is available.
//

import AppKit
import Foundation

struct OmniParserHarnessHealth: Decodable {
    let ok: Bool
    let service: String?
    let message: String?
}

struct OmniParserHarnessElement: Decodable {
    let bbox: [Double]
    let label: String?
    let source: String?
    let confidence: Double?
    let conf: Double?

    init(
        bbox: [Double],
        label: String?,
        source: String?,
        confidence: Double?
    ) {
        self.bbox = bbox
        self.label = label
        self.source = source
        self.confidence = confidence
        self.conf = nil
    }

    var normalizedSource: String {
        let rawSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawSource, !rawSource.isEmpty else { return "omniparser" }
        return rawSource.hasPrefix("omniparser") ? rawSource : "omniparser-\(rawSource)"
    }

    var normalizedConfidence: Double {
        confidence ?? conf ?? 0.75
    }
}

private struct OmniParserParseRequest: Encodable {
    let imageBase64: String
    let imageWidth: Int
    let imageHeight: Int
}

private struct OmniParserLegacyParseRequest: Encodable {
    let image: String
}

private struct OmniParserOfficialParseRequest: Encodable {
    let base64Image: String

    enum CodingKeys: String, CodingKey {
        case base64Image = "base64_image"
    }
}

private struct OmniParserParseResponse: Decodable {
    let ok: Bool?
    let elements: [OmniParserHarnessElement]?
    let parsedContentList: [OmniParserParsedContent]?

    enum CodingKeys: String, CodingKey {
        case ok
        case elements
        case parsedContentList = "parsed_content_list"
    }
}

private struct OmniParserParsedContent: Decodable {
    let type: String?
    let bbox: [Double]
    let content: String?
    let source: String?
    let interactivity: Bool?
}

struct OmniParserHarnessClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8765")!

    let baseURL: URL

    init(baseURL: URL = Self.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func health() async throws -> OmniParserHarnessHealth {
        do {
            let url = baseURL.appendingPathComponent("v1/health")
            let (data, response) = try await URLSession.shared.data(from: url)
            try ProviderRequestDiagnostics.validateHTTPResponse(
                response,
                data: data,
                serviceName: "OmniParser harness health",
                errorDomain: "OmniParserHarnessClient"
            )
            return try JSONDecoder().decode(OmniParserHarnessHealth.self, from: data)
        } catch {
            do {
                let url = baseURL.appendingPathComponent("probe/")
                let (_, response) = try await URLSession.shared.data(from: url)
                try ProviderRequestDiagnostics.validateHTTPResponse(
                    response,
                    data: Data(),
                    serviceName: "OmniParser official probe",
                    errorDomain: "OmniParserHarnessClient"
                )
                return OmniParserHarnessHealth(
                    ok: true,
                    service: "omniparser-official",
                    message: "Official /probe/ endpoint is reachable."
                )
            } catch {
                // Fall through to the lightweight local server shape.
            }

            let url = baseURL.appendingPathComponent("models")
            let (_, response) = try await URLSession.shared.data(from: url)
            try ProviderRequestDiagnostics.validateHTTPResponse(
                response,
                data: Data(),
                serviceName: "OmniParser legacy models",
                errorDomain: "OmniParserHarnessClient"
            )
            return OmniParserHarnessHealth(
                ok: true,
                service: "omniparser-legacy",
                message: "Legacy /models endpoint is reachable."
            )
        }
    }

    func parse(cgImage: CGImage) async throws -> [OmniParserHarnessElement] {
        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            throw NSError(
                domain: "OmniParserHarnessClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode screenshot for OmniParser."]
            )
        }

        do {
            return try await parseV1(
                jpegBase64: jpegData.base64EncodedString(),
                imageWidth: cgImage.width,
                imageHeight: cgImage.height
            )
        } catch {
            do {
                return try await parseOfficial(
                    jpegBase64: jpegData.base64EncodedString(),
                    imageWidth: cgImage.width,
                    imageHeight: cgImage.height
                )
            } catch {
                return try await parseLegacy(jpegBase64: jpegData.base64EncodedString())
            }
        }
    }

    private func parseV1(
        jpegBase64: String,
        imageWidth: Int,
        imageHeight: Int
    ) async throws -> [OmniParserHarnessElement] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/parse"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 8
        request.httpBody = try JSONEncoder().encode(
            OmniParserParseRequest(
                imageBase64: jpegBase64,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try ProviderRequestDiagnostics.validateHTTPResponse(
            response,
            data: data,
            serviceName: "OmniParser harness parse",
            errorDomain: "OmniParserHarnessClient"
        )

        let decoded = try JSONDecoder().decode(OmniParserParseResponse.self, from: data)
        return decoded.elements ?? elementsFromParsedContent(
            decoded.parsedContentList,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    private func parseOfficial(
        jpegBase64: String,
        imageWidth: Int,
        imageHeight: Int
    ) async throws -> [OmniParserHarnessElement] {
        var request = URLRequest(url: baseURL.appendingPathComponent("parse/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 12
        request.httpBody = try JSONEncoder().encode(OmniParserOfficialParseRequest(base64Image: jpegBase64))

        let (data, response) = try await URLSession.shared.data(for: request)
        try ProviderRequestDiagnostics.validateHTTPResponse(
            response,
            data: data,
            serviceName: "OmniParser official parse",
            errorDomain: "OmniParserHarnessClient"
        )

        let decoded = try JSONDecoder().decode(OmniParserParseResponse.self, from: data)
        return decoded.elements ?? elementsFromParsedContent(
            decoded.parsedContentList,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    private func parseLegacy(jpegBase64: String) async throws -> [OmniParserHarnessElement] {
        var request = URLRequest(url: baseURL.appendingPathComponent("parse"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 8
        request.httpBody = try JSONEncoder().encode(OmniParserLegacyParseRequest(image: jpegBase64))

        let (data, response) = try await URLSession.shared.data(for: request)
        try ProviderRequestDiagnostics.validateHTTPResponse(
            response,
            data: data,
            serviceName: "OmniParser legacy parse",
            errorDomain: "OmniParserHarnessClient"
        )

        let decoded = try JSONDecoder().decode(OmniParserParseResponse.self, from: data)
        return decoded.elements ?? []
    }

    private func elementsFromParsedContent(
        _ parsedContent: [OmniParserParsedContent]?,
        imageWidth: Int,
        imageHeight: Int
    ) -> [OmniParserHarnessElement] {
        (parsedContent ?? []).compactMap { content in
            guard content.bbox.count == 4 else { return nil }
            let bbox = content.bbox.map { value in
                value <= 1.0 ? value : value
            }
            let usesNormalizedCoordinates = bbox.allSatisfy { $0 >= 0 && $0 <= 1.0 }
            let pixelBox = usesNormalizedCoordinates
                ? [
                    bbox[0] * Double(imageWidth),
                    bbox[1] * Double(imageHeight),
                    bbox[2] * Double(imageWidth),
                    bbox[3] * Double(imageHeight)
                ]
                : bbox
            let source = [
                "official",
                content.type,
                content.source
            ]
            .compactMap { $0 }
            .joined(separator: "-")
            return OmniParserHarnessElement(
                bbox: pixelBox,
                label: content.content,
                source: source.isEmpty ? "official" : source,
                confidence: content.interactivity == false ? 0.65 : 0.82
            )
        }
    }
}
