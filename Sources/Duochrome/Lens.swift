import CoreImage
import Metal

/// Manual lens correction: distortion, chromatic aberration, vignetting, edge sharpness.
///
/// Applied right after RAW decoding, before retouching (source coordinate stage), so later coordinate mappings are unchanged.
/// Radius is normalized by half the photo diagonal (corner = 1), so it's independent of the preview scale.
enum Lens {
    static func isIdentity(_ s: DevelopSettings) -> Bool {
        s.lensDistortion == 0 && s.lensCA == 0 && s.lensCABlue == 0 && s.lensVignette == 0 && s.lensSharpFalloff == 0
    }

    static func apply(_ s: DevelopSettings, _ image: CIImage) -> CIImage {
        guard !isIdentity(s), !image.extent.isEmpty, !image.extent.isInfinite else { return image }
        var img = image
        let e = image.extent
        if s.lensDistortion != 0 || s.lensCA != 0 || s.lensCABlue != 0 {
            // k > 0: pulls corners inward to fix barrel distortion. Divided by (1 + k) so corners land on corners, no black border.
            // k < 0: samples toward the center to fix pincushion. Samples are always inside, so no black border.
            let k = s.lensDistortion / 100 * 0.15
            let norm: Float = k > 0 ? 1 / (1 + k) : 1
            // CA: scales channels by up to ±0.3% at the corners (about 13 px at a 45 MP corner).
            let cr = s.lensCA / 100 * 0.003, cb = s.lensCABlue / 100 * 0.003
            img = warp(image, params: [Float(e.midX), Float(e.midY), Float(hypot(e.width, e.height) / 2), k, norm, cr, cb, 0])
        }
        if s.lensVignette > 0 {
            // Brighten corners by up to 1 stop. Center unchanged (r² curve spreads wide).
            let gain = radial(e, center: 0, edge: 1).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(s.lensVignette / 100), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(s.lensVignette / 100), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(s.lensVignette / 100), w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            img = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: e)
        }
        if s.lensSharpFalloff > 0 {
            // Sharpen only the edges: blend an unsharp mask result through an r² mask.
            let radius = max(e.width, e.height) / 3000   // About 2.7 px on a 45 MP source, smaller in previews
            let sharp = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(radius, 0.5), kCIInputIntensityKey: s.lensSharpFalloff / 100 * 1.5,
            ]).cropped(to: e)
            img = sharp.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: radial(e, center: 0, edge: 1),
            ]).cropped(to: e)
        }
        return img
    }

    /// r² image from center 0 → corner 1 (gray).
    static func radial(_ e: CGRect, center: CGFloat, edge: CGFloat) -> CIImage {
        let half = hypot(e.width, e.height) / 2
        // CIRadialGradient is linear in radius. Apply gamma 2 to imitate a square.
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: e.midX, y: e.midY), "inputRadius0": 0, "inputRadius1": half,
            "inputColor0": CIColor(red: center, green: center, blue: center),
            "inputColor1": CIColor(red: edge, green: edge, blue: edge),
        ])!.outputImage!.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2]).cropped(to: e)
    }

    /// Kernels that move sample positions may need the whole input for one output cell, so the whole input region is given.
    static func warp(_ image: CIImage, params: [Float]) -> CIImage {
        do {
            return try WarpOp.apply(withExtent: image.extent, inputs: [image],
                                    arguments: ["kernel": "lens_warp", "params": params,
                                                "inputExtent": image.extent, "extent": image.extent]).cropped(to: image.extent)
        } catch {
            NSLog("렌즈 왜곡 실패: \(error)")
            return image
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Texture row 0 is the top of the region (large y).
    inline float4 at(texture2d<half, access::sample> src, float2 w, float2 o) {
        constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
        float2 t = w - o;
        return float4(src.sample(s, float2(t.x, float(src.get_height()) - t.y)));
    }

    // Output position → where to sample the original (distorted) photo. p[0..1] center, p[2] half diagonal, p[3] k, p[4] normalization, p[5] red, p[6] blue
    // q[0..1] output region origin, q[2..3] input region origin (Core Image coordinates, y up)
    kernel void lens_warp(texture2d<half, access::sample> src [[texture(0)]],
                          texture2d<half, access::write> dst [[texture(1)]],
                          constant float *p [[buffer(0)]],
                          constant float *q [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float H = float(dst.get_height());
        float2 pos = float2(q[0] + gid.x + 0.5, q[1] + (H - gid.y - 0.5));
        float2 c = float2(p[0], p[1]);
        float2 d = (pos - c) / p[2];
        float r2 = dot(d, d);
        float2 g = c + d * (1.0 + p[3] * r2) * p[4] * p[2];
        float2 gr = c + (g - c) * (1.0 + p[5] * r2);
        float2 gb = c + (g - c) * (1.0 + p[6] * r2);
        float2 o = float2(q[2], q[3]);
        float4 cg = at(src, g, o);
        float out_r = at(src, gr, o).r, out_b = at(src, gb, o).b;
        dst.write(half4(out_r, cg.g, out_b, cg.a), gid);
    }
    """

    static let library: MTLLibrary = {
        do { return try Render.device.makeLibrary(source: source, options: nil) }
        catch { fatalError("렌즈 커널 컴파일 실패: \(error)") }
    }()

    static let pipeline: MTLComputePipelineState = {
        try! Render.device.makeComputePipelineState(function: library.makeFunction(name: "lens_warp")!)
    }()
}

final class WarpOp: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["inputExtent"] as? CGRect) ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let buffer = output.metalCommandBuffer, let dst = output.metalTexture,
              let encoder = buffer.makeComputeCommandEncoder() else { return }
        let pso = Lens.pipeline
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input.metalTexture, index: 0)
        encoder.setTexture(dst, index: 1)
        var p = (arguments?["params"] as? [Float]) ?? []
        while p.count < 8 { p.append(0) }
        var q: [Float] = [Float(output.region.minX), Float(output.region.minY), Float(input.region.minX), Float(input.region.minY)]
        encoder.setBytes(&p, length: 4 * p.count, index: 0)
        encoder.setBytes(&q, length: 4 * q.count, index: 1)
        let w = pso.threadExecutionWidth, h = pso.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        PixelOp.clearOutside(dst, region: output.region, extent: arguments?["extent"] as? CGRect, buffer: buffer)
    }
}
