import AppKit
import CoreImage
import ImageIO
import AVFoundation

/// Depth map for lens blur: from depth data in the photo (iPhone portrait HEIC etc.), AI subject separation, or a layer mask.
/// The depth map is grayscale, 0 near – 1 far, stored in view coordinates after current geometry and crop.
enum LensDepth {
    /// Depth (or disparity) data in the photo file → source-coordinate grayscale (0 near – 1 far)
    static func auxiliary(_ url: URL) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) as? [AnyHashable: Any],
                  var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { continue }
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            var img = CIImage(cvPixelBuffer: depth.depthDataMap)
            // Disparity is larger when near → invert, to 0–1
            let e = img.extent
            var mm = [Float](repeating: 0, count: 4)
            let minmax = img.applyingFilter("CIAreaMinMaxRed", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
            Render.context.render(minmax, toBitmap: &mm, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let lo = mm[0], hi = max(mm[1], mm[0] + 1e-4)
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(-1 / (hi - lo)), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: CGFloat(-1 / (hi - lo)), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: CGFloat(-1 / (hi - lo)), y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: CGFloat(hi / (hi - lo)), y: CGFloat(hi / (hi - lo)), z: CGFloat(hi / (hi - lo)), w: 1)])
            return img
        }
        return nil
    }
}

extension MainWindowController {
    /// Source-coordinate grayscale → mapped to view coordinates (geometry, crop), saved, and set as the depth map on the selected layer's lens blur
    func setLensDepth(_ nativeDepth: CIImage) {
        guard let doc = photo, var s = photo?.settings, let id = layersTab.selectedID ?? s.layers.last?.id,
              let i = s.layers.firstIndex(where: { $0.id == id }) else {
            let a = NSAlert(); a.messageText = "렌즈 흐림을 걸 레이어를 고르세요"; a.runModal(); return
        }
        let n = doc.nativeSize
        let sc: CGFloat = 0.25
        let fitted = nativeDepth.transformed(by: .init(scaleX: n.width * sc / nativeDepth.extent.width, y: n.height * sc / nativeDepth.extent.height))
            .transformed(by: .init(translationX: -nativeDepth.extent.minX * n.width * sc / nativeDepth.extent.width, y: -nativeDepth.extent.minY * n.height * sc / nativeDepth.extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: n.width * sc, height: n.height * sc))
        let eff = SliderResponse.effective(s)
        let shaped = Geometry.crop(eff, Geometry.transform(eff, fitted.clampedToExtent().cropped(to: fitted.extent), scale: sc))
        let r = shaped.extent.integral
        guard let png = Render.context.pngRepresentation(of: shaped.cropped(to: r), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let file = try? LayerImageStore.importData(png, ext: "png") else { return }
        var fx = s.layers[i].adjust.fx
        if let k = fx.firstIndex(where: { $0.kind == "lensBlur" }) {
            fx[k].text = "depth:" + file
            fx[k].params["source"] = 1
        } else {
            var e = LayerEffect(kind: "lensBlur")
            e.text = "depth:" + file
            e.params["source"] = 1
            e.params["focus"] = 0.1
            e.params["depth"] = 0.3
            fx.append(e)
        }
        s.layers[i].adjust.effects = fx
        replaceSettings(s, recordUndo: true, label: "렌즈 흐림 깊이 맵")
        layersTab.sync(s)
    }

    /// AI subject separation: subject near (0), background far (1), soft boundary
    @objc func lensDepthFromAI(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        window?.subtitle = "깊이 맵 만드는 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let file = AISelect.mask(doc, target: .background)
            DispatchQueue.main.async {
                self?.window?.subtitle = ""
                guard let file, let img = Layers.sourceImage(file) else { NSSound.beep(); return }
                self?.setLensDepth(img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).cropped(to: img.extent))
            }
        }
    }

    /// Depth data in the photo (iPhone portrait etc.)
    @objc func lensDepthFromPhoto(_ sender: Any?) {
        guard let doc = photo, let d = LensDepth.auxiliary(URL(fileURLWithPath: doc.url.path)) else {
            let a = NSAlert(); a.messageText = "이 사진에는 깊이 자료가 없습니다"; a.informativeText = "아이폰 인물 사진(HEIC) 등에만 있습니다. AI 피사체 분리나 레이어 마스크를 쓰세요."; a.runModal(); return
        }
        setLensDepth(d)
    }

    /// Mask of the selected layer (white is far)
    @objc func lensDepthFromMask(_ sender: Any?) {
        guard let doc = photo, let id = layersTab.selectedID, let l = doc.settings.layers.first(where: { $0.id == id }), l.mask.kind != .full else { NSSound.beep(); return }
        let n = doc.nativeSize
        let m = Layers.maskImage(l.mask, scale: 1, native: n, shape: { img, _ in img }, base: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: n)))
        setLensDepth(m)
    }
}
