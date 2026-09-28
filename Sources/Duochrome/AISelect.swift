import AppKit
import CoreImage
import Vision

/// AI 선택: Apple Vision으로 맥 안에서 피사체·사람 마스크를 만든다.
/// 마스크는 원본 좌표 그림(1/4 크기) 흑백 PNG로 레이어 그림 폴더에 저장하고, 조정 레이어의 마스크가 된다.
enum AISelect {
    enum Target: String { case subject = "피사체", background = "배경", person = "사람" }

    /// 원본 좌표 그림에서 마스크를 만든다 (백그라운드에서 불러도 된다). 실패하면 nil.
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
        // 그림 크기에 맞추고 흑백으로
        let me = m.extent
        m = m.transformed(by: .init(scaleX: e.width / me.width, y: e.height / me.height))
        if target == .background { m = m.applyingFilter("CIColorInvert") }
        guard let png = Render.context.pngRepresentation(of: m.cropped(to: CGRect(origin: .zero, size: e.size)), format: .L8,
                                                          colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }
}

extension MainWindowController {
    /// AI 선택 레이어를 더한다 (계산은 백그라운드, 1초 안팎).
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
