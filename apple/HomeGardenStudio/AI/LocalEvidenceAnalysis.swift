import Foundation
import Vision
import NaturalLanguage
import ImageIO

nonisolated struct LocalImageObservation: Identifiable, Sendable { let label: String; let confidence: Float; var id: String { label } }
nonisolated struct LocalEvidenceResult: Sendable { let text: String; let language: String?; let observations: [LocalImageObservation] }
nonisolated enum LocalEvidenceAnalysis {
    @concurrent static func analyze(_ bytes: Data) async throws -> LocalEvidenceResult {
        guard !bytes.isEmpty, bytes.count <= ImportService.maxFileBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            throw LocalAIError.invalidResponse
        }
        try Task.checkCancellation()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.automaticallyDetectsLanguage = true
        let classification = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([textRequest, classification])
        try Task.checkCancellation()
        let text = String((textRequest.results ?? []).prefix(50).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(10_000))
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let observations = (classification.results ?? []).filter { $0.confidence >= 0.2 }.prefix(5).map { LocalImageObservation(label: $0.identifier, confidence: $0.confidence) }
        return LocalEvidenceResult(text: text, language: recognizer.dominantLanguage?.rawValue, observations: observations)
    }
}
