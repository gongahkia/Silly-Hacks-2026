import AngyCore
import CoreGraphics
import Foundation
import Vision

final class WindowOCRService {
    func extractText(for window: TrackedWindow) -> TextObservation? {
        guard window.windowID != 0 else {
            return nil
        }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results ?? []
        let recognized = observations.compactMap { observation -> (String, Float)? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return (candidate.string, candidate.confidence)
        }

        let rawText = recognized.map { $0.0 }.joined(separator: "\n")
        let normalizedText = TextNormalizer.normalize(rawText)

        guard !normalizedText.isEmpty else {
            return nil
        }

        let confidence = recognized.isEmpty
            ? 0
            : Double(recognized.map { $0.1 }.reduce(Float.zero, +)) / Double(recognized.count)

        return TextObservation(
            timestamp: Date(),
            source: .ocr,
            rawText: rawText,
            normalizedText: normalizedText,
            confidence: confidence
        )
    }
}
