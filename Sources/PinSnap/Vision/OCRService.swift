import CoreGraphics
import Foundation
import Vision

/// 本地 Vision OCR / 条码。REQ: R-01–R-03
public enum OCRService {
    public static func recognizeText(in image: CGImage, joinLines: Bool = true) async throws -> String {
        let result = try await recognizeLines(in: image)
        let parts = result.lines.map(\.text)
        return joinLines ? parts.joined(separator: " ") : parts.joined(separator: "\n")
    }

    /// 带几何框的行级识别，供可选文字叠层使用。
    public static func recognizeLines(in image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if #available(macOS 13.0, *) {
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                    }
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
                        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                            return nil
                        }
                        return OCRLine(text: text, normalizedRect: observation.boundingBox)
                    }
                    continuation.resume(returning: OCRResult(lines: lines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func recognizeBarcodes(in image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectBarcodesRequest()
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    let codes = (request.results ?? []).compactMap(\.payloadStringValue)
                    continuation.resume(returning: codes)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Prefer barcode payload when present, else OCR text.
    public static func extract(in image: CGImage) async throws -> String {
        let codes = try await recognizeBarcodes(in: image)
        if let first = codes.first { return first }
        return try await recognizeText(in: image)
    }
}
