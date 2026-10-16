import Cocoa
import Vision

class OCRTool {
    private var activeAreaSelector: AreaSelector?

    func captureAndRecognize(completion: @escaping (Result<String, Error>) -> Void) {
        let selector = AreaSelector { [weak self] result in
            self?.activeAreaSelector = nil  // Release after completion
            switch result {
            case .success(let (rect, _)):
                guard let image = ScreenGrabber.capture(rect: rect) else {
                    ScreenGrabber.reportFailureIfNeeded()
                    completion(.failure(CaptureError.captureFailed))
                    return
                }
                self?.recognizeText(in: image, completion: completion)

            case .failure(let error):
                completion(.failure(error))
            }
        }
        activeAreaSelector = selector  // Retain until completion fires
        selector.show()
    }

    private func recognizeText(in image: CGImage, completion: @escaping (Result<String, Error>) -> Void) {
        // Delivers exactly one result on the main thread, whichever path finishes first
        // (request handler or a thrown error from perform).
        var delivered = false
        let deliver: (Result<String, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !delivered else { return }
                delivered = true
                if case .success(let text) = result {
                    // Copy to clipboard
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
                completion(result)
            }
        }

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                deliver(.failure(error))
                return
            }

            let text = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""

            if text.isEmpty {
                deliver(.failure(CaptureError.captureFailed))
            } else {
                deliver(.success(text))
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                NSLog("OCR failed: \(error)")
                deliver(.failure(error))
            }
        }
    }
}
