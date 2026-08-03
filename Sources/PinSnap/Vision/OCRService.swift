import CoreGraphics
import Foundation
import Vision

/// v1.1 OCR（本地 Vision）。REQ: R-01–R-03
public enum OCRService {
    public static func recognizeText(in image: CGImage, joinLines: Bool = true) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let parts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return joinLines ? parts.joined(separator: " ") : parts.joined(separator: "\n")
    }

    public static func recognizeBarcodes(in image: CGImage) async throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Prefer barcode payload when present, else OCR text.
    public static func extract(in image: CGImage) async throws -> String {
        let codes = try await recognizeBarcodes(in: image)
        if let first = codes.first { return first }
        return try await recognizeText(in: image)
    }
}
