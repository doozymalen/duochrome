import CoreImage
import Metal

/// 자체 GPU 커널. Metal 소스를 앱이 실행될 때 컴파일한다(`makeLibrary(source:)`).
/// 그래서 Xcode의 metal 컴파일러(Metal Toolchain) 없이도 빌드된다.
///
/// 각 커널은 `PixelOp`(CIImageProcessorKernel)로 Core Image 그래프 안에 끼워 넣는다.
/// Core Image가 타일과 필요한 영역(ROI)을 그대로 관리해 준다.
enum GPU {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float a; float b; float c; float d; };

    // 화면 밝기에 가까운 값. 선형 값에 감마를 씌워 사람 눈 기준으로 나눈다.
    inline float perceptual(float3 c) {
        float y = dot(max(c, 0.0), float3(0.2627, 0.6780, 0.0593));   // Rec.2020 밝기 계수
        return pow(y, 1.0 / 2.2);
    }

    // 가이디드 필터 1단계: r = I, g = I²
    kernel void luma_sq(texture2d<half, access::read> src [[texture(0)]],
                        texture2d<half, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float l = perceptual(float3(src.read(gid).rgb));
        dst.write(half4(l, l * l, 0, 1), gid);
    }

    // 가이디드 필터 2단계: 평균 I, 평균 I²에서 a, b를 구한다. p.a = eps
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

    // 클래리티 적용: 기저 = 평균 a·I + 평균 b (가장자리를 지키는 흐림). 세부 = I − 기저.
    // p.a = 양(-1~1). 밝기만 바꾸고 색 비율은 지킨다. 섀도·하이라이트 끝은 덜 건드린다.
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
        // 0 내추럴(채도 약간), 1 펀치(세게 + 채도), 2 뉴트럴(채도 그대로), 3 클래식(가장자리 보존 약하게, 세게)
        float amt = p.a * (method == 1 ? 1.4 : (method == 3 ? 1.2 : 1.0));
        float nl = max(l + detail * amt * 2.0 * protect, 0.0);
        float gain = l > 1e-4 ? pow(nl / l, 2.2) : 1.0;
        float3 rgb = c.rgb * gain;   // 밝기만 곱하므로 색 비율(채도)은 그대로다
        float satBoost = method == 0 ? 0.5 : (method == 1 ? 1.5 : 0.0);
        if (satBoost > 0.0) {
            float y = dot(rgb, float3(0.2627, 0.6780, 0.0593));
            rgb = max(y + (rgb - y) * (1.0 + abs(detail) * amt * satBoost), 0.0);
        }
        dst.write(half4(half3(rgb), half(c.a)), gid);
    }

    // 필름 그레인: n은 0~1 균등 난수를 흐린 것. 중간 톤에서 가장 세고 양끝은 약하다. p.a = 세기
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
        // p.b = 1 이면 색 입자 (채널마다 다른 난수)
        float3 n = p.b > 0.5 ? nz.rgb : float3(nz.r);
        float3 gain = max(1.0 + p.a * n * w * 2.0, 0.0);
        dst.write(half4(half3(c.rgb * gain), half(c.a)), gid);
    }

    // 복제 도장: 마스크만큼 옮겨 온 그림으로 바꾼다. p.a = 불투명도
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

    // 복구 브러시: 옮겨 온 그림의 세부 + 대상 둘레 고리의 저주파.
    // numT/den = 대상 고리 평균, numS/den = 원본 고리 평균 (같은 고리 모양이라 분모가 같다).
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
        // 곱셈형으로 옮긴다: 밝기 차가 큰 곳에서 뺄셈형보다 색이 덜 뒤집힌다.
        // 비율은 0.5~2배로 묶는다. 고리 가중치가 얇은 곳(획 끝)에서 나눗셈이 튀어 흰 점이 생겼다.
        float3 ratio = clamp((lowT + 1e-3) / (lowS + 1e-3), 0.5, 2.0);
        float3 healed = b.rgb * ratio;
        float m = float(mask.read(gid).r) * p.a;
        dst.write(half4(half3(mix(a.rgb, healed, m)), half(a.a)), gid);
    }

    // 루마 레인지: 아래 그림의 밝기가 [lo, hi] 안일 때만 마스크를 남긴다. p.c = 경계 부드러움
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

    // 하드 혼합: 두 값의 합이 1 이상이면 1, 아니면 0 (채널마다, 화면 감마 기준)
    // p.a = 칠 불투명도. 1보다 작으면 결과가 부드러워진다: (b − (1 − a)·f) / (1 − f)
    // 위 레이어가 투명한 곳(이미지 레이어 바깥)은 아래를 그대로 둔다.
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

    // 기본 모습 보정표 앞: 선형 → 0~1로 잘라 감마 2.2 부호화
    kernel void look_encode(texture2d<half, access::read> src [[texture(0)]],
                            texture2d<half, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        dst.write(half4(half3(pow(clamp(c.rgb, 0.0, 1.0), 1.0 / 2.2)), 1), gid);
    }

    // 기본 모습 보정표 뒤: 감마 풀기 + 1.0을 넘었던 만큼 더하기 (하이라이트 여유를 지킨다)
    kernel void look_decode(texture2d<half, access::read> mapped [[texture(0)]],
                            texture2d<half, access::read> orig [[texture(1)]],
                            texture2d<half, access::write> dst [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 m = pow(max(float3(mapped.read(gid).rgb), 0.0), 2.2);
        float3 o = float3(orig.read(gid).rgb);
        dst.write(half4(half3(m + max(o - 1.0, 0.0)), 1), gid);
    }

    // 하이 패스: 원본 − 흐린 것 + 0.5 (오버레이·소프트 라이트로 섞으면 세부만 남는다)
    kernel void high_pass(texture2d<half, access::read> src [[texture(0)]],
                          texture2d<half, access::read> blurred [[texture(1)]],
                          texture2d<half, access::write> dst [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 d = float3(src.read(gid).rgb) - float3(blurred.read(gid).rgb);
        dst.write(half4(half3(d + 0.5), 1), gid);
    }

    // 색역 경고: 자르기 전과 뒤가 다르면(색역 밖) 회색으로
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

    // 하이라이트 곡선 (docs/SLIDERS.md). y = 선형 휘도, v = -1~1.
    // v < 0 (되살림): 화면 밝기 L(감마 2.2) 0.5 아래는 그대로, 0.85에서 최대 1스톱, 흰색 1.0에서 0.5스톱 누르고,
    //                1.0을 넘는 날아간 부분은 흰색 아래로 접는다.
    // v > 0 (밝게): 0.5~1.0 구간을 u + v·u²(1-u)로 올린다 (0.5·흰색 고정, L 0.83이 약 0.91로).
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

    // 하이라이트 (한 픽셀씩): 조정 레이어·LUT 내보내기용. p.a = -1~1. 휘도만 바꾸고 색 비율은 지킨다.
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

    // 하이라이트 (국소): 곡선을 가장자리를 지키는 기저 밝기(가이디드 필터)에 걸고, 그 배율을 픽셀에 곱한다.
    // 밝은 구역 전체는 곡선대로 옮기되 그 안의 질감(세부 대비)은 그대로 남는다. p.a = -1~1
    kernel void highlight_local(texture2d<half, access::read> src [[texture(0)]],
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
        float gain = highlight_y(yb, p.a) / yb;
        dst.write(half4(half3(c.rgb * gain), c.a), gid);
    }

    // 섀도 (docs/SLIDERS.md): p.a = 양 0~1. 화면 밝기 0.5 위는 그대로, 0.2 아래는 최대 1스톱(×a) 밝힌다.
    // 곱하기라 순수한 검정은 검정으로 남고, 색 비율은 지킨다.
    kernel void shadow_curve(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::write> dst [[texture(1)]],
                             constant Params &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = float4(src.read(gid));
        float y = dot(max(c.rgb, 0.0), float3(0.2627, 0.6780, 0.0593));
        if (y <= 1e-6) { dst.write(half4(c), gid); return; }
        float a = clamp(p.a, 0.0, 1.0);
        float L = pow(min(y, 1.0), 1.0 / 2.2);
        float t = clamp((0.5 - L) / 0.5, 0.0, 1.0);
        float y1 = y * exp2(a * smoothstep(0.0, 0.6, t));
        dst.write(half4(half3(c.rgb * (y1 / y)), c.a), gid);
    }

    // 범위 밖 지우기: 텍스처 좌표 (x0, y0) ~ (x1, y1) 밖을 투명하게. p = (x0, y0, x1, y1)
    kernel void clear_outside(texture2d<half, access::write> dst [[texture(0)]],
                              constant Params &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float x = float(gid.x) + 0.5, y = float(gid.y) + 0.5;
        if (x < p.a || y < p.b || x > p.c || y > p.d) dst.write(half4(0), gid);
    }

    // 디졸브: 마스크 × (난수 < 불투명도 ? 1 : 0)
    kernel void dissolve_mask(texture2d<half, access::read> mask [[texture(0)]],
                              texture2d<half, access::read> noise [[texture(1)]],
                              texture2d<half, access::write> dst [[texture(2)]],
                              constant Params &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float m = float(mask.read(gid).r) * (float(noise.read(gid).r) < p.a ? 1.0 : 0.0);
        dst.write(half4(m, m, m, 1), gid);
    }

    // 핫 픽셀: 중간값과 차이가 임계값(p.a, 화면 감마 기준)을 넘는 픽셀만 중간값으로.
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

    // 언샤프 마스크: 세부 = 원본 − 흐림. 임계값(p.b) 아래는 무시, 밝은 헤일로는 p.c만큼 줄인다. p.a = 양
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
        if (d > 0.0) d *= 1.0 - p.c * 0.7;          // 밝은 테두리(헤일로)를 줄인다
        float nl = max(l + d * p.a, 0.0);
        float gain = l > 1e-4 ? pow(nl / l, 2.2) : 1.0;
        dst.write(half4(half3(c.rgb * gain), half(c.a)), gid);
    }

    // 디헤이즈 1단계: 다크 채널 = 세 채널 중 최솟값 (화면 감마 기준).
    kernel void dark_channel(texture2d<half, access::read> src [[texture(0)]],
                             texture2d<half, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = pow(max(float3(src.read(gid).rgb), 0.0), 1.0 / 2.2);
        float d = min(c.r, min(c.g, c.b));
        dst.write(half4(d, d, d, 1), gid);
    }

    // 디헤이즈 적용 (He 2009): J = (I − A) / max(t, t0) + A, t = 1 − w · dark / A.
    // p.a = 양(0~1), p.b = 대기광 A, p.c/p.d 사용 안 함.
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
        // 안개 색: 색조 p.c(°), 양 p.d. 회색 대기광을 그 색 쪽으로 기울인다.
        float h = fmod(p.c, 360.0) / 60.0;
        float x = 1.0 - fabs(fmod(h, 2.0) - 1.0);
        float3 hc = h < 1 ? float3(1, x, 0) : h < 2 ? float3(x, 1, 0) : h < 3 ? float3(0, 1, x) : h < 4 ? float3(0, x, 1) : h < 5 ? float3(x, 0, 1) : float3(1, 0, x);
        hc -= dot(hc, float3(0.2627, 0.6780, 0.0593));
        float3 A3 = max(A * (1.0 + p.d * 0.6 * hc), 0.02);
        float3 j = (g - A3) / max(t, 0.4) + A3;   // 하한이 낮으면 하늘이 짙은 남색으로 뒤집힌다
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

    /// 픽셀 단위 커널 하나를 CIImage 여러 장에 건다. 모두 같은 영역을 읽는다.
    static func run(_ kernel: String, _ inputs: [CIImage], params: [Float] = [], extent: CGRect) -> CIImage {
        var p = params
        while p.count < 4 { p.append(0) }
        do {
            // 출력 범위 밖은 투명해야 한다. 자르지 않으면 줄여서 바탕 위에 놓을 때 범위 밖이 검게 칠해졌다 (여백 번짐).
            return try PixelOp.apply(withExtent: extent, inputs: inputs,
                                     arguments: ["kernel": kernel, "params": p, "extent": extent]).cropped(to: extent)
        } catch {
            NSLog("GPU \(kernel) 실패: \(error)")
            return inputs[0]
        }
    }
}

final class PixelOp: CIImageProcessorKernel {
    /// 입력 텍스처를 출력 영역에 맞춘다. 같으면 그대로, 다르면 겹치는 부분을 복사한 새 텍스처.
    /// 텍스처 행 0은 영역의 위쪽(큰 y)이다.
    /// Core Image가 선언한 범위보다 넓은 영역을 요청할 때가 있다. 커널은 그 영역을 모두 불투명하게 채우므로
    /// 범위 밖을 투명하게 지운다 (안 지우면 줄여서 바탕 위에 놓을 때 여백이 검게 번졌다).
    static func clearOutside(_ dst: MTLTexture, region r: CGRect, extent e: CGRect?, buffer: MTLCommandBuffer) {
        guard let e, !e.contains(r) else { return }
        // 텍스처 행 0은 영역의 위쪽(큰 y)
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
        // 입력이 출력 전체를 덮지 못하면 겹치는 곳만 복사한다 (나머지는 0)
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
        // 커널은 입력과 출력이 같은 자리라고 보고 gid로 읽는다. 그런데 Core Image는 미리 계산해 둔 더 큰 입력을
        // 그대로 넘길 때가 있다 (보정표 커널에서 124×124를 요청했는데 2136×1424가 들어와 엉뚱한 화소를 읽었다 →
        // 리터칭 점이 검게 칠해지고, 보정이 여백으로 번짐). 영역이 다르면 출력 자리만큼 잘라 새 텍스처로 넘긴다.
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
    /// 가장자리 밖을 늘여 붙인 뒤 흐리고 원래 크기로 자른다. 경계가 어두워지지 않는다.
    func blurred(_ radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return self }
        return clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
    }
}
