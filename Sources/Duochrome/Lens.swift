import CoreImage
import Metal

/// 손 렌즈 보정: 왜곡, 색수차, 주변부 광량, 주변부 선명도.
///
/// RAW 디코딩 바로 뒤, 리터칭보다 앞(원본 좌표 단계)에서 건다. 그래서 뒤의 좌표 변환은 그대로다.
/// 반경은 사진 대각선의 절반으로 나눈 값(모서리 = 1)이라 미리보기 배율과 상관없다.
enum Lens {
    static func isIdentity(_ s: DevelopSettings) -> Bool {
        s.lensDistortion == 0 && s.lensCA == 0 && s.lensCABlue == 0 && s.lensVignette == 0 && s.lensSharpFalloff == 0
    }

    static func apply(_ s: DevelopSettings, _ image: CIImage) -> CIImage {
        guard !isIdentity(s), !image.extent.isEmpty, !image.extent.isInfinite else { return image }
        var img = image
        let e = image.extent
        if s.lensDistortion != 0 || s.lensCA != 0 || s.lensCABlue != 0 {
            // k > 0: 모서리를 안으로 당겨 술통형을 편다. 모서리가 모서리에 오게 (1 + k)로 나눠 검은 테가 없다.
            // k < 0: 가운데 쪽을 읽어 실패형을 편다. 읽는 자리가 늘 안쪽이라 검은 테가 없다.
            let k = s.lensDistortion / 100 * 0.15
            let norm: Float = k > 0 ? 1 / (1 + k) : 1
            // 색수차: 모서리에서 채널 크기를 최대 ±0.3% 바꾼다 (45MP 모서리에서 약 13px).
            let cr = s.lensCA / 100 * 0.003, cb = s.lensCABlue / 100 * 0.003
            img = warp(image, params: [Float(e.midX), Float(e.midY), Float(hypot(e.width, e.height) / 2), k, norm, cr, cb, 0])
        }
        if s.lensVignette > 0 {
            // 모서리를 최대 1스톱 밝힌다. 가운데는 그대로 (r² 곡선이라 넓게 퍼진다).
            let gain = radial(e, center: 0, edge: 1).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(s.lensVignette / 100), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(s.lensVignette / 100), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(s.lensVignette / 100), w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            img = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: e)
        }
        if s.lensSharpFalloff > 0 {
            // 가장자리만 더 선명하게: 언샤프 마스크 결과를 r² 마스크로 섞는다.
            let radius = max(e.width, e.height) / 3000   // 45MP 원본에서 약 2.7px, 미리보기에서는 작아진다
            let sharp = img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(radius, 0.5), kCIInputIntensityKey: s.lensSharpFalloff / 100 * 1.5,
            ]).cropped(to: e)
            img = sharp.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: radial(e, center: 0, edge: 1),
            ]).cropped(to: e)
        }
        return img
    }

    /// 가운데 0 → 모서리 1인 r² 이미지 (회색).
    static func radial(_ e: CGRect, center: CGFloat, edge: CGFloat) -> CIImage {
        let half = hypot(e.width, e.height) / 2
        // CIRadialGradient는 반경에 선형이다. 제곱을 흉내 내려고 감마 2를 씌운다.
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: e.midX, y: e.midY), "inputRadius0": 0, "inputRadius1": half,
            "inputColor0": CIColor(red: center, green: center, blue: center),
            "inputColor1": CIColor(red: edge, green: edge, blue: edge),
        ])!.outputImage!.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2]).cropped(to: e)
    }

    /// 읽는 자리를 옮기는 커널은 출력 한 칸에 입력 전체가 필요할 수 있어 입력 영역을 통째로 준다.
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

    // 텍스처 행 0은 영역의 위쪽(큰 y)이다.
    inline float4 at(texture2d<half, access::sample> src, float2 w, float2 o) {
        constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
        float2 t = w - o;
        return float4(src.sample(s, float2(t.x, float(src.get_height()) - t.y)));
    }

    // 출력 자리 → 원래(왜곡된) 사진에서 읽을 자리. p[0..1] 중심, p[2] 반 대각선, p[3] k, p[4] 정규화, p[5] 빨강, p[6] 파랑
    // q[0..1] 출력 영역 원점, q[2..3] 입력 영역 원점 (Core Image 좌표, y 위로)
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
