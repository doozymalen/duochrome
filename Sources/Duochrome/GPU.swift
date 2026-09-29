import CoreImage
import Metal

/// Custom GPU kernels. Metal source is compiled at app launch (`makeLibrary(source:)`),
/// so it builds without Xcode's metal compiler (Metal Toolchain).
///
/// Each kernel plugs into the Core Image graph as a `PixelOp` (CIImageProcessorKernel).
/// Core Image keeps managing tiles and the required region (ROI).
enum GPU {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float a; float b; float c; float d; };

    // Value close to display brightness. Gamma applied to linear values to split by perceived brightness.
    inline float perceptual(float3 c) {
        float y = dot(max(c, 0.0), float3(0.2627, 0.6780, 0.0593));   // Rec.2020 luminance coefficients
        return pow(y, 1.0 / 2.2);
    }

    // Guided filter step 1: r = I, g = I²
    kernel void luma_sq(texture2d<half, access::read> src [[texture(0)]],
                        texture2d<half, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float l = perceptual(float3(src.read(gid).rgb));
        dst.write(half4(l, l * l, 0, 1), gid);
    }

    // Guided filter step 2: a, b from mean I and mean I². p.a = eps
    kernel void guided_ab(texture2d<half, access::read> m [[texture(0)]],
                          texture2d<half, access::write> dst [[texture(1)]],
                          constant Params &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 v = float2(m.read(gid).rg);
        float var_ = max(v.y - v.x * v.x, 0.0);
        float a = var_ / (var_ + p.a);
        dst.write(half4(a, v.x - a * v.x, 0, 1), gid);
    }

    // Clarity: base = mean a·I + mean b (edge-preserving blur). detail = I − base.
    // p.a = amount (-1–1). Changes only brightness, keeping color ratios. Touches the shadow/highlight ends less.
    kernel void clarity_apply(texture2d<half, access::read> src [[texture(0)]],
                              texture2d<half, access::read> lum [[texture(1)]],
                              texture2d<half, access::read> ab [[texture(2)]],
                              texture2d<half, access::write> dst [[texture(3)]],
                              constant Params &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float l = float(lum.read(gid).r);
        float2 k = float2(ab.read(gid).rg);
        float base = k.x * l + k.y;
        float detail = l - base;
        float protect = smoothstep(0.0, 0.15, l) * (1.0 - smoothstep(0.85, 1.0, l));
        int method = int(p.b + 0.5);
        // 0 natural (slight saturation), 1 punch (strong + saturation), 2 neutral (saturation unchanged), 3 classic (weak edge preservation, strong)
        float amt = p.a * (method == 1 ? 1.4 : (method == 3 ? 1.2 : 1.0));
        float nl = max(l + detail * amt * 2.0 * protect, 0.0);
        float gain = l > 1e-4 ? pow(nl / l, 2.2) : 1.0;
        float3 rgb = c.rgb * gain;   // Only brightness is multiplied, so color ratios (saturation) stay
        float satBoost = method == 0 ? 0.5 : (method == 1 ? 1.5 : 0.0);
        if (satBoost > 0.0) {
            float y = dot(rgb, float3(0.2627, 0.6780, 0.0593));
            rgb = max(y + (rgb - y) * (1.0 + abs(detail) * amt * satBoost), 0.0);
        }
        dst.write(half4(half3(rgb), half(c.a)), gid);
    }

    // Film grain: n is blurred 0–1 uniform noise. Strongest in midtones, weaker at the ends. p.a = strength
    kernel void grain_apply(texture2d<half, access::read> src [[texture(0)]],
                            texture2d<half, access::read> noise [[texture(1)]],
                            texture2d<half, access::write> dst [[texture(2)]],
                            constant Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float4 nz = float4(noise.read(gid)) - 0.5;
        float l = perceptual(c.rgb);
        float w = 0.25 + 3.0 * l * (1.0 - l);
        // p.b = 1 means color grain (different noise per channel)
        float3 n = p.b > 0.5 ? nz.rgb : float3(nz.r);
        float3 gain = max(1.0 + p.a * n * w * 2.0, 0.0);
        dst.write(half4(half3(c.rgb * gain), half(c.a)), gid);
    }

    // Clone stamp: replace with the offset image by the mask. p.a = opacity
    kernel void clone_apply(texture2d<half, access::read> dst0 [[texture(0)]],
                            texture2d<half, access::read> src [[texture(1)]],
                            texture2d<half, access::read> mask [[texture(2)]],
                            texture2d<half, access::write> dst [[texture(3)]],
                            constant Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 a = float4(dst0.read(gid)), b = float4(src.read(gid));
        float m = float(mask.read(gid).r) * p.a;
        dst.write(half4(mix(a, b, m)), gid);
    }

    // Healing brush: detail from the offset image + low frequencies from a ring around the target.
    // numT/den = target ring mean, numS/den = source ring mean (same ring shape, so the same denominator).
    kernel void heal_apply(texture2d<half, access::read> dst0 [[texture(0)]],
                           texture2d<half, access::read> src [[texture(1)]],
                           texture2d<half, access::read> numT [[texture(2)]],
                           texture2d<half, access::read> numS [[texture(3)]],
                           texture2d<half, access::read> den [[texture(4)]],
                           texture2d<half, access::read> mask [[texture(5)]],
                           texture2d<half, access::write> dst [[texture(6)]],
                           constant Params &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 a = float4(dst0.read(gid)), b = float4(src.read(gid));
        float d = max(float(den.read(gid).r), 0.05);
        float3 lowT = float3(numT.read(gid).rgb) / d;
        float3 lowS = float3(numS.read(gid).rgb) / d;
        // Multiplicative transfer: flips color less than subtractive where the brightness difference is large.
        // Ratio clamped to 0.5–2×. Where ring weights are thin (stroke ends) the division spiked and made white dots.
        float3 ratio = clamp((lowT + 1e-3) / (lowS + 1e-3), 0.5, 2.0);
        float3 healed = b.rgb * ratio;
        float m = float(mask.read(gid).r) * p.a;
        dst.write(half4(half3(mix(a.rgb, healed, m)), half(a.a)), gid);
    }

    // Luma range: keep the mask only where the underlying brightness is within [lo, hi]. p.c = edge softness
    kernel void luma_range(texture2d<half, access::read> mask [[texture(0)]],
                           texture2d<half, access::read> base [[texture(1)]],
                           texture2d<half, access::write> dst [[texture(2)]],
                           constant Params &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float m = float(mask.read(gid).r);
        float l = perceptual(float3(base.read(gid).rgb));
        float w = smoothstep(p.a - p.c, p.a + p.c, l) * (1.0 - smoothstep(p.b - p.c, p.b + p.c, l));
        if (p.a <= 0.0) w = 1.0 - smoothstep(p.b - p.c, p.b + p.c, l);
        if (p.b >= 1.0) w = p.a <= 0.0 ? 1.0 : smoothstep(p.a - p.c, p.a + p.c, l);
        float v = m * w;
        dst.write(half4(v, v, v, 1), gid);
    }

    // Hard mix: 1 if the sum of the two values is ≥ 1, else 0 (per channel, in display gamma)
    // p.a = fill opacity. Below 1 the result softens: (b − (1 − a)·f) / (1 − f)
    // Where the upper layer is transparent (outside an image layer), keep what's below.
    kernel void hard_mix(texture2d<half, access::read> top [[texture(0)]],
                         texture2d<half, access::read> base [[texture(1)]],
                         texture2d<half, access::write> dst [[texture(2)]],
                         constant Params &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 t = float4(top.read(gid)), bs = float4(base.read(gid));
        float ta = t.a;
        float3 a = pow(max(t.rgb / max(ta, 1e-4), 0.0), 1.0 / 2.2), b = pow(max(bs.rgb, 0.0), 1.0 / 2.2);
        float f = p.a;
        float3 r = f >= 0.999 ? step(1.0, a + b) : clamp((b - (1.0 - a) * f) / (1.0 - f), 0.0, 1.0);
        float3 lin = pow(r, 2.2);
        dst.write(half4(half3(mix(bs.rgb, lin, ta)), 1), gid);
    }

    // Before the base look table: linear → clamp to 0–1 and encode gamma 2.2
    kernel void look_encode(texture2d<half, access::read> src [[texture(0)]],
                            texture2d<half, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        dst.write(half4(half3(pow(clamp(c.rgb, 0.0, 1.0), 1.0 / 2.2)), 1), gid);
    }

    // After the base look table: decode gamma + add back what exceeded 1.0 (keeps highlight headroom)
    kernel void look_decode(texture2d<half, access::read> mapped [[texture(0)]],
                            texture2d<half, access::read> orig [[texture(1)]],
                            texture2d<half, access::write> dst [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 m = pow(max(float3(mapped.read(gid).rgb), 0.0), 2.2);
        float3 o = float3(orig.read(gid).rgb);
        dst.write(half4(half3(m + max(o - 1.0, 0.0)), 1), gid);
    }

    // High pass: source − blurred + 0.5 (blended with overlay/soft light, only detail remains)
    kernel void high_pass(texture2d<half, access::read> src [[texture(0)]],
                          texture2d<half, access::read> blurred [[texture(1)]],
                          texture2d<half, access::write> dst [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 d = float3(src.read(gid).rgb) - float3(blurred.read(gid).rgb);
        dst.write(half4(half3(d + 0.5), 1), gid);
    }

    // Gamut warning: gray where values differ before and after clamping (out of gamut)
    kernel void gamut_warn(texture2d<half, access::read> orig [[texture(0)]],
                           texture2d<half, access::read> clamped [[texture(1)]],
                           texture2d<half, access::read> proof [[texture(2)]],
                           texture2d<half, access::write> dst [[texture(3)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 d = abs(float3(orig.read(gid).rgb) - float3(clamped.read(gid).rgb));
        bool out = max(d.x, max(d.y, d.z)) > 0.004;
        dst.write(out ? half4(0.22, 0.22, 0.22, 1) : proof.read(gid), gid);
    }

    // Highlights curve (docs/SLIDERS.md). y = linear luminance, v = -1–1.
    // v < 0 (recover): display brightness L (gamma 2.2) unchanged below 0.5, up to 1 stop at 0.85, 0.5 stop at white 1.0,
    //                and blown values above 1.0 fold back below white.
    // v > 0 (brighten): lifts the 0.5–1.0 range by u + v·u²(1-u) (0.5 and white fixed, L 0.83 → about 0.91).
    inline float highlight_y(float y, float v) {
        if (y <= 1e-5 || v == 0.0) return y;
        float L = pow(min(y, 1.0), 1.0 / 2.2);
        float t = clamp((L - 0.5) / 0.5, 0.0, 1.0);
        if (v > 0.0) {
            if (y >= 1.0 || L <= 0.5) return y;
            float u = t + min(v, 1.0) * t * t * (1.0 - t);
            return pow(0.5 + 0.5 * u, 2.2);
        }
        float a = min(-v, 1.0);
        float w = smoothstep(0.0, 0.7, t) * (1.0 - 0.5 * smoothstep(0.7, 1.0, t));
        float y1 = min(y, 1.0) * exp2(-a * w);
        if (y > 1.0) {
            float base = exp2(-a * 0.5);
            float folded = base + (1.0 - base) * (1.0 - exp(-(y - 1.0) * 3.0));
            y1 = mix(y * base, folded, a);
        }
        return y1;
    }

    // Highlights (per pixel): for adjustment layers and LUT export. p.a = -1–1. Changes luminance only, keeping color ratios.
    kernel void highlight_curve(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::write> dst [[texture(1)]],
                             constant Params &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float y = dot(max(c.rgb, 0.0), float3(0.2627, 0.6780, 0.0593));
        if (y <= 1e-5) { dst.write(half4(c), gid); return; }
        dst.write(half4(half3(c.rgb * (highlight_y(y, p.a) / y)), c.a), gid);
    }

    // Shadows curve (docs/SLIDERS.md). y = linear luminance, v = -1–1.
    // v > 0 (brighten): display brightness L unchanged above 0.5, up to 1 stop brighter below 0.2 (multiplicative, so pure black stays black).
    // v < 0 (deepen): keeps 0.5 and black, lowers what's between (u + |v|·u²(1-u), L 0.17 → about 0.09).
    inline float shadow_y(float y, float v) {
        if (y <= 1e-6 || v == 0.0) return y;
        float L = pow(min(y, 1.0), 1.0 / 2.2);
        float t = clamp((0.5 - L) / 0.5, 0.0, 1.0);
        if (v > 0.0) return y * exp2(min(v, 1.0) * smoothstep(0.0, 0.6, t));
        if (L >= 0.5) return y;
        float u = t + min(-v, 1.0) * t * t * (1.0 - t);
        return pow(max(0.5 - 0.5 * u, 0.0), 2.2);
    }

    // Shadows (per pixel): for adjustment layers and LUT export. p.a = -1–1. Changes luminance only, keeping color ratios.
    kernel void shadow_curve(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::write> dst [[texture(1)]],
                             constant Params &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float y = dot(max(c.rgb, 0.0), float3(0.2627, 0.6780, 0.0593));
        if (y <= 1e-6) { dst.write(half4(c), gid); return; }
        dst.write(half4(half3(c.rgb * (shadow_y(y, p.a) / y)), c.a), gid);
    }

    // Highlights/shadows (local): curves applied to an edge-preserving base luminance (guided filter), ratio multiplied into the pixel.
    // Whole bright/dark regions follow the curves while texture (detail contrast) within them stays. p.a = highlights, p.b = shadows (-1–1)
    kernel void tone_local(texture2d<half, access::read> src [[texture(0)]],
                                texture2d<half, access::read> lum [[texture(1)]],
                                texture2d<half, access::read> ab [[texture(2)]],
                                texture2d<half, access::write> dst [[texture(3)]],
                                constant Params &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float l = float(lum.read(gid).r);
        float2 k = float2(ab.read(gid).rg);
        float yb = pow(max(k.x * l + k.y, 1e-4), 2.2);
        float gain = shadow_y(highlight_y(yb, p.a), p.b) / yb;
        dst.write(half4(half3(c.rgb * gain), c.a), gid);
    }

    // Clear outside a range: transparent outside texture coordinates (x0, y0) – (x1, y1). p = (x0, y0, x1, y1)
    kernel void clear_outside(texture2d<half, access::write> dst [[texture(0)]],
                              constant Params &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float x = float(gid.x) + 0.5, y = float(gid.y) + 0.5;
        if (x < p.a || y < p.b || x > p.c || y > p.d) dst.write(half4(0), gid);
    }

    // Dissolve: mask × (random < opacity ? 1 : 0)
    kernel void dissolve_mask(texture2d<half, access::read> mask [[texture(0)]],
                              texture2d<half, access::read> noise [[texture(1)]],
                              texture2d<half, access::write> dst [[texture(2)]],
                              constant Params &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float m = float(mask.read(gid).r) * (float(noise.read(gid).r) < p.a ? 1.0 : 0.0);
        dst.write(half4(m, m, m, 1), gid);
    }

    // Hot pixels: only pixels differing from the median by more than the threshold (p.a, display gamma) become the median.
    kernel void hot_pixel(texture2d<half, access::read> src [[texture(0)]],
                          texture2d<half, access::read> med [[texture(1)]],
                          texture2d<half, access::write> dst [[texture(2)]],
                          constant Params &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid)), m = float4(med.read(gid));
        float d = fabs(perceptual(c.rgb) - perceptual(m.rgb));
        dst.write(half4(d > p.a ? m : c), gid);
    }

    // Unsharp mask: detail = source − blur. Ignored below threshold (p.b), bright halos reduced by p.c. p.a = amount
    kernel void usm_apply(texture2d<half, access::read> src [[texture(0)]],
                          texture2d<half, access::read> blur [[texture(1)]],
                          texture2d<half, access::write> dst [[texture(2)]],
                          constant Params &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float l = perceptual(c.rgb), lb = perceptual(float3(blur.read(gid).rgb));
        float d = l - lb;
        d = fabs(d) < p.b ? 0.0 : d - sign(d) * p.b;
        if (d > 0.0) d *= 1.0 - p.c * 0.7;          // Reduce bright rims (halos)
        float nl = max(l + d * p.a, 0.0);
        float gain = l > 1e-4 ? pow(nl / l, 2.2) : 1.0;
        dst.write(half4(half3(c.rgb * gain), half(c.a)), gid);
    }

    // Dehaze step 1: dark channel = min of the three channels (display gamma).
    kernel void dark_channel(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = pow(max(float3(src.read(gid).rgb), 0.0), 1.0 / 2.2);
        float d = min(c.r, min(c.g, c.b));
        dst.write(half4(d, d, d, 1), gid);
    }

    // Dehaze apply (He 2009): J = (I − A) / max(t, t0) + A, t = 1 − w · dark / A.
    // p.a = amount (0–1), p.b = airlight A, p.c/p.d unused.
    kernel void dehaze_apply(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::read> dark [[texture(1)]],
                             texture2d<half, access::write> dst [[texture(2)]],
                             constant Params &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float3 g = pow(max(c.rgb, 0.0), 1.0 / 2.2);
        float A = max(p.b, 0.05);
        float t = 1.0 - p.a * 0.8 * float(dark.read(gid).r) / A;
        // Haze color: hue p.c (°), amount p.d. Tilts the gray airlight toward that color.
        float h = fmod(p.c, 360.0) / 60.0;
        float x = 1.0 - fabs(fmod(h, 2.0) - 1.0);
        float3 hc = h < 1 ? float3(1, x, 0) : h < 2 ? float3(x, 1, 0) : h < 3 ? float3(0, 1, x) : h < 4 ? float3(0, x, 1) : h < 5 ? float3(x, 0, 1) : float3(1, 0, x);
        hc -= dot(hc, float3(0.2627, 0.6780, 0.0593));
        float3 A3 = max(A * (1.0 + p.d * 0.6 * hc), 0.02);
        float3 j = (g - A3) / max(t, 0.4) + A3;   // A low floor flips the sky to deep navy
        j = max(j, 0.0);
        dst.write(half4(half3(pow(j, 2.2)), half(c.a)), gid);
    }
    """

    static let library: MTLLibrary = {
        do {
            return try Render.device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("GPU 커널 컴파일 실패: \(error)")
        }
    }()

    private static var pipelines: [String: MTLComputePipelineState] = [:]
    private static let lock = NSLock()

    static func pipeline(_ name: String) -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[name] { return p }
        guard let fn = library.makeFunction(name: name),
              let p = try? Render.device.makeComputePipelineState(function: fn) else {
            fatalError("GPU 커널 없음: \(name)")
        }
        pipelines[name] = p
        return p
    }

    /// Applies one per-pixel kernel to several CIImages. All read the same region.
    static func run(_ kernel: String, _ inputs: [CIImage], params: [Float] = [], extent: CGRect) -> CIImage {
        var p = params
        while p.count < 4 { p.append(0) }
        do {
            // Outside the output extent must be transparent. Without cropping, downscaling onto a background painted it black (margin bleed).
            return try PixelOp.apply(withExtent: extent, inputs: inputs,
                                     arguments: ["kernel": kernel, "params": p, "extent": extent]).cropped(to: extent)
        } catch {
            NSLog("GPU \(kernel) 실패: \(error)")
            return inputs[0]
        }
    }
}

final class PixelOp: CIImageProcessorKernel {
    /// Fits an input texture to the output region. Same region: as is; otherwise a new texture with the overlap copied.
    /// Texture row 0 is the top of the region (large y).
    /// Core Image sometimes requests a region wider than the declared extent. The kernel fills that whole region opaque,
    /// so clear outside the extent (otherwise margins bled black when downscaled onto a background).
    static func clearOutside(_ dst: MTLTexture, region r: CGRect, extent e: CGRect?, buffer: MTLCommandBuffer) {
        guard let e, !e.contains(r) else { return }
        // Texture row 0 is the top of the region (large y)
        var p: [Float] = [Float(e.minX - r.minX), Float(r.maxY - e.maxY), Float(e.maxX - r.minX), Float(r.maxY - e.minY)]
        guard let enc = buffer.makeComputeCommandEncoder() else { return }
        let pso = GPU.pipeline("clear_outside")
        enc.setComputePipelineState(pso)
        enc.setTexture(dst, index: 0)
        enc.setBytes(&p, length: 16, index: 0)
        let w = pso.threadExecutionWidth, h = pso.maxTotalThreadsPerThreadgroup / w
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    static func aligned(_ input: CIImageProcessorInput, to output: CIImageProcessorOutput, buffer: MTLCommandBuffer,
                        size: (Int, Int)) -> MTLTexture? {
        guard let t = input.metalTexture else { return nil }
        let ir = input.region, orr = output.region
        if ir == orr || (t.width == size.0 && t.height == size.1 && ir.origin == orr.origin) { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: size.0, height: size.1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let tmp = Render.device.makeTexture(descriptor: desc), let blit = buffer.makeBlitCommandEncoder() else { return t }
        let ox = Int((orr.minX - ir.minX).rounded()), oy = Int((ir.maxY - orr.maxY).rounded())
        // If the input doesn't cover the whole output, copy only the overlap (rest is 0)
        let sx = max(ox, 0), sy = max(oy, 0)
        let dx = sx - ox, dy = sy - oy
        let w = min(t.width - sx, size.0 - dx), h = min(t.height - sy, size.1 - dy)
        if w > 0, h > 0 {
            blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: sx, y: sy, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: tmp, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: dx, y: dy, z: 0))
        }
        blit.endEncoding()
        return tmp
    }

    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, let buffer = output.metalCommandBuffer, let dst = output.metalTexture,
              let name = arguments?["kernel"] as? String else { return }
        // Kernels assume input and output share positions and read by gid. But Core Image sometimes passes a larger
        // precomputed input as is (a look-table kernel requested 124×124 but got 2136×1424 and read wrong pixels →
        // retouch spots painted black, adjustments bled into margins). If regions differ, crop to the output and pass a new texture.
        let textures = inputs.map { aligned($0, to: output, buffer: buffer, size: (dst.width, dst.height)) }
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        let pso = GPU.pipeline(name)
        encoder.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        if ProcessInfo.processInfo.environment["DUOCHROME_GPU_DEBUG"] != nil {
            print("GPU \(name) out \(output.region) tex \(dst.width)x\(dst.height)",
                  inputs.map { "in \($0.region) tex \($0.metalTexture?.width ?? -1)x\($0.metalTexture?.height ?? -1)" })
        }
        encoder.setTexture(dst, index: inputs.count)
        var params = (arguments?["params"] as? [Float]) ?? [0, 0, 0, 0]
        encoder.setBytes(&params, length: MemoryLayout<Float>.size * 4, index: 0)
        let w = pso.threadExecutionWidth, h = pso.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        clearOutside(dst, region: output.region, extent: arguments?["extent"] as? CGRect, buffer: buffer)
    }
}

extension CIImage {
    /// Extends the edges outward, blurs, and crops back to size. Edges don't darken.
    func blurred(_ radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return self }
        return clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
    }
}
