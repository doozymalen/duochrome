import AppKit
import CoreImage
import Vision

/// AI selection: builds subject/person masks on-device with Apple Vision.
/// Masks are saved as grayscale PNGs (quarter size, source coordinates) in the layer image folder and become adjustment-layer masks.
enum AISelect {
    enum Target: String { case subject = "피사체", background = "배경", person = "사람" }

    /// Builds a mask from a source-coordinate image (safe to call in the background). nil on failure.
    static func mask(_ doc: RawDocument, target: Target) -> String? {
        let img = doc.nativePreview(scale: 0.25)
        let e = img.extent
        guard let cg = Render.context.createCGImage(img, from: e, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg)
        var maskCI: CIImage?
        do {
            switch target {
            case .subject, .background:
                let req = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([req])
                guard let obs = req.results?.first else { return nil }
                let buf = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
                maskCI = CIImage(cvPixelBuffer: buf)
            case .person:
                let req = VNGeneratePersonSegmentationRequest()
                req.qualityLevel = .accurate
                req.outputPixelFormat = kCVPixelFormatType_OneComponent8
                try handler.perform([req])
                guard let buf = req.results?.first?.pixelBuffer else { return nil }
                maskCI = CIImage(cvPixelBuffer: buf)
            }
        } catch {
            NSLog("AI 선택 실패: %@", "\(error)")
            return nil
        }
        guard var m = maskCI else { return nil }
        // Fit to image size, grayscale
        let me = m.extent
        m = m.transformed(by: .init(scaleX: e.width / me.width, y: e.height / me.height))
        if target == .background { m = m.applyingFilter("CIColorInvert") }
        guard let png = Render.context.pngRepresentation(of: m.cropped(to: CGRect(origin: .zero, size: e.size)), format: .L8,
                                                          colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }
}

extension MainWindowController {
    /// Adds an AI selection layer (computed in the background, about a second).
    func addAISelection(_ target: AISelect.Target, done: (() -> Void)? = nil) {
        guard let doc = photo else { NSSound.beep(); return }
        NSCursor.operationNotAllowed.push()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let file = AISelect.mask(doc, target: target)
            DispatchQueue.main.async {
                NSCursor.pop()
                guard let self, self.photo === doc else { return }
                guard let file else {
                    let a = NSAlert()
                    a.messageText = "\(target.rawValue)을(를) 찾지 못했습니다"
                    a.runModal()
                    return
                }
                self.layersTab.addLayer(.full, native: doc.nativeSize)
                guard var s = self.photo?.settings, let i = s.layers.indices.last else { return }
                s.layers[i].mask.kind = .image
                s.layers[i].mask.maskFile = file
                s.layers[i].name = "\(target.rawValue) 선택 \(s.layers.count)"
                self.apply(s, dragging: false)
                self.layersTab.sync(s)
                done?()
            }
        }
    }

    @objc func selectSubjectAI(_ sender: Any?) { addAISelection(.subject) }
    @objc func selectBackgroundAI(_ sender: Any?) { addAISelection(.background) }
    @objc func selectPersonAI(_ sender: Any?) { addAISelection(.person) }
}
