import UniformTypeIdentifiers
import CoreImage
import QuartzCore

/// 개발용 자체 검사 (DUOCHROME_SELFTEST=1). 결과를 로그로 남기고 종료한다.
/// 좌표 변환처럼 그림으로 보기 어려운 것을 숫자로 확인한다.
enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "통과" : "실패")  \(name)  \(detail)")
            if !ok { failures += 1 }
        }

        let native = CGSize(width: 8192, height: 5464)
        var s = DevelopSettings()
        s.quarterTurns = 1; s.flipH = 1; s.rotation = 4.5
        s.keystoneV = 35; s.keystoneH = -20; s.keystoneAspect = 10
        s.crop = CropRect(CGRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6))

        // 1. 되돌리기: 화면 → 원본 → 화면이 제자리로 오는가
        var worst = 0.0
        for i in 0..<200 {
            let p = CGPoint(x: Double((i * 7919) % 4000) + 200, y: Double((i * 104729) % 3000) + 300)
            let back = Geometry.toDisplay(Geometry.fromDisplay(p, s, native: native, fullFrame: false),
                                          s, native: native, fullFrame: false)
            worst = max(worst, hypot(back.x - p.x, back.y - p.y))
        }
        check("좌표 되돌리기", worst < 0.01, String(format: "최대 오차 %.5f px", worst))

        // 2. 그림과 좌표가 같은 자리를 가리키는가: 원본의 점 하나를 그려서 찾는다
        let dot = CGPoint(x: 3100, y: 2200)
        let img = CIImage(color: .white).cropped(to: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: native)))
        let shaped = Geometry.crop(s, Geometry.transform(s, img, scale: 1))
        let predicted = Geometry.toDisplay(dot, s, native: native, fullFrame: false)
        let win = CGRect(x: predicted.x - 40, y: predicted.y - 40, width: 80, height: 80).integral
        var px = [Float](repeating: 0, count: Int(win.width * win.height) * 4)
        Render.context.render(shaped, toBitmap: &px, rowBytes: Int(win.width) * 16, bounds: win,
                              format: .RGBAf, colorSpace: nil)
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<Int(win.height) {
            for x in 0..<Int(win.width) {
                let v = Double(px[(y * Int(win.width) + x) * 4])
                sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5); sw += v
            }
        }
        if sw > 0 {
            let found = CGPoint(x: win.minX + sx / sw, y: win.minY + sy / sw)
            let err = hypot(found.x - predicted.x, found.y - predicted.y)
            check("그림 위치 = 계산 위치", err < 1.5, String(format: "예상 (%.1f, %.1f) 실제 (%.1f, %.1f) 오차 %.2f px",
                                                      predicted.x, predicted.y, found.x, found.y, err))
        } else {
            check("그림 위치 = 계산 위치", false, "점을 찾지 못함 (예상 \(predicted))")
        }

        // 3. 선 긋기 키스톤: 알려진 답(세로 40, 회전 2°)을 되찾는가
        var target = DevelopSettings()
        target.keystoneV = 40; target.rotation = 2
        let current = DevelopSettings()
        let lines: [(CGPoint, CGPoint)] = [(1500, 800, 1500, 4600), (6400, 700, 6400, 4800)].map { l in
            // 목표 설정에서 세로인 선을, 지금 설정(보정 없음) 화면 좌표로 옮긴다.
            let a = Geometry.fromDisplay(CGPoint(x: l.0, y: l.1), target, native: native, fullFrame: true)
            let b = Geometry.fromDisplay(CGPoint(x: l.2, y: l.3), target, native: native, fullFrame: true)
            return (Geometry.toDisplay(a, current, native: native, fullFrame: true),
                    Geometry.toDisplay(b, current, native: native, fullFrame: true))
        }
        let solved = Geometry.solveVerticals(lines, current, native: native, fullFrame: true)
        check("선 긋기 키스톤", abs(solved.keystoneV - 40) < 1.5 && abs(solved.rotation - 2) < 0.2,
              String(format: "세로 %.2f (40), 회전 %.2f° (2)", solved.keystoneV, solved.rotation))

        // 6. 사용자 GPU 커널이 입력을 제자리에서 읽는가 (위아래만 변하는 그림을 그대로 통과시킨다)
        do {
            let box = CGRect(x: 0, y: 0, width: 200, height: 200)
            let vgrad = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 200),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])!.outputImage!.cropped(to: box)
            let zeroMask = CIImage(color: .black).cropped(to: box)
            let region = CGRect(x: 40, y: 60, width: 80, height: 50)
            let passed = GPU.run("clone_apply", [vgrad.cropped(to: region), vgrad.cropped(to: region), zeroMask.cropped(to: region)],
                                 params: [1], extent: region)
            var a = [Float](repeating: 0, count: 80 * 50 * 4), b = a
            Render.context.render(vgrad, toBitmap: &a, rowBytes: 80 * 16, bounds: region, format: .RGBAf, colorSpace: nil)
            Render.context.render(passed, toBitmap: &b, rowBytes: 80 * 16, bounds: region, format: .RGBAf, colorSpace: nil)
            var diff = 0.0
            for i in stride(from: 0, to: a.count, by: 4) { diff += Double(abs(a[i] - b[i])) }
            check("GPU 커널 제자리 읽기", diff / Double(80 * 50) < 1e-3,
                  String(format: "평균 차 %.5f · 첫 줄 %.3f→%.3f · 끝 줄 %.3f→%.3f", diff / Double(80 * 50),
                         a[0], b[0], a[a.count - 4], b[b.count - 4]))
        }

        // 8. 컬러 에디터·스킨 톤 (LUT 변환 함수를 바로 확인)
        do {
            var k = ColorLUT.Key()
            k.editor[5].dSat = -100            // 파랑 채도 없애기
            k.editor[0].dHue = 30              // 빨강 색조 +30°
            let blue = ColorLUT.transform(k, SIMD3(0.1, 0.2, 0.9))
            let green = ColorLUT.transform(k, SIMD3(0.1, 0.8, 0.2))
            let gray = ColorLUT.transform(k, SIMD3(0.5, 0.5, 0.5))
            let red = ColorLUT.transform(k, SIMD3(0.9, 0.1, 0.1))
            let (bh, bs, _) = ColorLUT.hsv(blue), (rh, _, _) = ColorLUT.hsv(red)
            func maxDiff(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
            let gDiff = maxDiff(green, SIMD3(0.1, 0.8, 0.2)), grayDiff = maxDiff(gray, SIMD3(0.5, 0.5, 0.5))
            check("컬러 에디터 (파랑 채도 −100, 빨강 색조 +30°)", bs < 0.02 && abs(rh - 30) < 3 && gDiff < 0.01 && grayDiff < 0.001,
                  String(format: "파랑 채도 %.2f (색조 %.0f), 빨강 색조 %.0f°, 초록 변화 %.3f, 회색 변화 %.4f", bs, bh, rh, gDiff, grayDiff))
            var sk = ColorLUT.Key()
            sk.skin = SkinTone(enabled: true, hue: 25, sat: 0.45, light: 0.75, width: 40, hueAmount: 100, satAmount: 100, lightAmount: 100)
            let skin1 = ColorLUT.hsv(ColorLUT.transform(sk, ColorLUT.rgb(38, 0.6, 0.6)))
            let skin2 = ColorLUT.hsv(ColorLUT.transform(sk, ColorLUT.rgb(15, 0.3, 0.85)))
            let far = ColorLUT.hsv(ColorLUT.transform(sk, ColorLUT.rgb(200, 0.6, 0.6)))
            check("스킨 톤 균일화", abs(skin1.0 - skin2.0) < 3 && abs(skin1.1 - skin2.1) < 0.05 && abs(far.0 - 200) < 0.5,
                  String(format: "피부1 %.0f°/%.2f, 피부2 %.0f°/%.2f (가까워져야), 하늘 %.0f° 그대로", skin1.0, skin1.1, skin2.0, skin2.1, far.0))
        }

        // 9. 단일 픽셀 제거·밝기 커브·채널 레벨
        do {
            let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            // 왼쪽 어둡고 오른쪽 밝은 경계 + 어두운 쪽 가운데 밝은 점 하나
            let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: rect)
            let edge = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
            let dot = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 12, y: 30, width: 1, height: 1))
            let bakedCG = Render.context.createCGImage(dot.composited(over: edge.composited(over: dark)), from: rect, format: .RGBAh,
                                                       colorSpace: Render.workingSpace)!
            let src = CIImage(cgImage: bakedCG)
            let out = Develop.hotPixels(src, amount: 0.6)
            func v(_ i: CIImage, _ x: Int, _ y: Int) -> Float {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0]
            }
            let dotBefore = v(src, 12, 30), dotAfter = v(out, 12, 30), edgeL = v(out, 31, 20), edgeR = v(out, 32, 20)
            check("단일 픽셀 제거", dotAfter < dotBefore * 0.3 && abs(edgeL - v(src, 31, 20)) < 0.01 && abs(edgeR - v(src, 32, 20)) < 0.01,
                  String(format: "점 %.2f → %.2f, 경계 그대로 (%.2f|%.2f)", dotBefore, dotAfter, edgeL, edgeR))

            var k = ColorLUT.Key()
            k.luma = ToneCurve(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.7), CGPoint(x: 1, y: 1)])
            let c0 = SIMD3<Float>(0.6, 0.3, 0.2)
            let c1 = ColorLUT.transform(k, c0)
            let ratio0 = c0.x / c0.z, ratio1 = c1.x / c1.z
            check("밝기 커브 (색 비율 그대로)", c1.y > c0.y && abs(ratio1 - ratio0) < 0.01,
                  String(format: "밝아짐 G %.2f → %.2f, 빨강/파랑 비율 %.2f → %.2f", c0.y, c1.y, ratio0, ratio1))

            var sl = DevelopSettings()
            sl.levelsRGB[0] = [0, 1, 1, 0, 0.8]     // 빨강 출력 흰색 0.8
            let data = Develop.toneCurve(sl)!
            let arr = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let top = Array(arr.suffix(3))
            check("채널별 레벨 (빨강만)", abs(top[0] - 0.8) < 0.01 && abs(top[1] - 1) < 0.01 && abs(top[2] - 1) < 0.01,
                  String(format: "흰색 → R %.2f G %.2f B %.2f", top[0], top[1], top[2]))
        }

        // 10. 손 렌즈 보정: 점이 반경 방향으로 맞는 쪽에 옮겨지는가 (y 뒤집힘·영역 원점까지)
        do {
            let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
            let bg = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: rect)
            let dot = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 420, y: 290, width: 3, height: 3))
            let cg = Render.context.createCGImage(dot.composited(over: bg), from: rect, format: .RGBAh, colorSpace: Render.workingSpace)!
            let src = CIImage(cgImage: cg).transformed(by: .init(translationX: rect.minX, y: rect.minY))
            func brightest(_ i: CIImage, channel: Int) -> CGPoint {
                let w = Int(rect.width), h = Int(rect.height)
                var buf = [Float](repeating: 0, count: w * h * 4)
                Render.context.render(i, toBitmap: &buf, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
                var best = 0, bv: Float = -1
                for j in 0..<(w * h) where buf[j * 4 + channel] > bv { bv = buf[j * 4 + channel]; best = j }
                // 비트맵 행 0은 위쪽
                return CGPoint(x: rect.minX + CGFloat(best % w), y: rect.maxY - 1 - CGFloat(best / w))
            }
            let p0 = brightest(src, channel: 1)
            var ls = DevelopSettings()
            ls.lensDistortion = 0.0001
            let pid = brightest(Lens.apply(ls, src), channel: 1)
            ls.lensDistortion = 100
            let pd = brightest(Lens.apply(ls, src), channel: 1)
            ls.lensDistortion = 0; ls.lensCA = 100
            let caOut = Lens.apply(ls, src)
            let pr = brightest(caOut, channel: 0), pg = brightest(caOut, channel: 1)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            func r(_ p: CGPoint) -> CGFloat { hypot(p.x - c.x, p.y - c.y) }
            let sameDir = ((pd.x - c.x) * (p0.x - c.x) + (pd.y - c.y) * (p0.y - c.y)) > 0 && abs((pd.x - c.x) * (p0.y - c.y) - (pd.y - c.y) * (p0.x - c.x)) / r(p0) < 2
            check("렌즈 왜곡 (그대로·바깥으로·색수차)", pid == p0 && r(pd) > r(p0) + 2 && sameDir && r(pr) < r(pg) && pg == p0,
                  String(format: "점 (%.0f,%.0f), 0이면 (%.0f,%.0f), +100이면 (%.0f,%.0f), 색수차 빨강 (%.0f,%.0f) 초록 (%.0f,%.0f)",
                         p0.x, p0.y, pid.x, pid.y, pd.x, pd.y, pr.x, pr.y, pg.x, pg.y))
            ls.lensCA = 0; ls.lensVignette = 100
            let lv = Lens.apply(ls, bg)
            func v(_ i: CIImage, _ x: CGFloat, _ y: CGFloat) -> Float {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0]
            }
            let base = v(bg, c.x, c.y), mid = v(lv, c.x, c.y), corner = v(lv, rect.minX + 1, rect.minY + 1)
            check("주변부 광량 (모서리 +1스톱)", abs(mid - base) < base * 0.05 && corner > base * 1.9,
                  String(format: "가운데 %.4f, 모서리 %.4f (원래 %.4f)", mid, corner, base))
        }

        // 11. 자동 키스톤: 알고 있는 값으로 비튼 건물 격자를 선 찾기로 되돌리는가
        do {
            let W = 1200, H = 800
            let native = CGSize(width: W, height: H)
            let truth = (v: Float(30), h: Float(-20), r: Float(3))
            let rot = Geometry.rotationTransform(truth.r, w: native.width, h: native.height)
            let hm = Geometry.keystoneHomography(v: truth.v, h: truth.h, aspect: 0, w: native.width, h: native.height)
            // 곧은 격자(보정 뒤 모습)를 거꾸로 옮겨 "찍힌 사진"을 만든다.
            func shot(_ p: CGPoint) -> CGPoint { hm.inverse.apply(p).applying(rot.inverted()) }
            let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(gray: 0.25, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.setStrokeColor(gray: 0.85, alpha: 1); ctx.setLineWidth(5)
            for x in stride(from: 250, through: 950, by: 175) {
                ctx.move(to: shot(CGPoint(x: x, y: 120))); ctx.addLine(to: shot(CGPoint(x: x, y: 680)))
            }
            for y in stride(from: 160, through: 640, by: 160) {
                ctx.move(to: shot(CGPoint(x: 200, y: y))); ctx.addLine(to: shot(CGPoint(x: 1000, y: y)))
            }
            ctx.strokePath()
            let img = CIImage(cgImage: ctx.makeImage()!)
            let found = LineDetector.detect(img)
            let v = found.vertical.map { ($0.a, $0.b) }, hz = found.horizontal.map { ($0.a, $0.b) }
            let full = Geometry.solveKeystone(vertical: v, horizontal: hz, DevelopSettings(), native: native, robust: true)
            let onlyV = Geometry.solveKeystone(vertical: v, horizontal: [], DevelopSettings(), native: native, robust: true)
            check("자동 키스톤 (전체: 세로 30, 가로 −20, 회전 3°)",
                  abs(full.v - truth.v) < 3 && abs(full.h - truth.h) < 3 && abs(full.rotation - truth.r) < 0.5 && onlyV.h == 0,
                  String(format: "선 세로 %d·가로 %d → 세로 %.1f, 가로 %.1f, 회전 %.2f° (세로만: %.1f, %.2f°)",
                         v.count, hz.count, full.v, full.h, full.rotation, onlyV.v, onlyV.rotation))
        }

        // 12. 이미지 레이어·칠 불투명도·그룹, 그룹 옮기기 규칙
        do {
            let native = CGSize(width: 1200, height: 800)
            let rect = CGRect(origin: .zero, size: native)
            let base = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: rect)
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
            let png = Render.context.pngRepresentation(of: red, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            let file = try! LayerImageStore.importData(png, ext: "png")
            var img = AdjustLayer(name: "그림")
            img.kind = "image"
            img.image = LayerImage(file: file, cx: 600, cy: 400, width: 400)
            func render(_ layers: [AdjustLayer]) -> (Float, Float) {
                let out = Layers.apply(layers, to: base, guide: base, scale: 1, guideScale: 1, native: native, shape: { m, _ in m })
                func v(_ x: CGFloat, _ y: CGFloat) -> Float {
                    var p = [Float](repeating: 0, count: 4)
                    Render.context.render(out, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    return p[0]
                }
                return (v(600, 400), v(50, 50))
            }
            let full = render([img])
            var half = img; half.fill = 0.5
            let filled = render([half])
            var grp = [img]
            let gid = LayerTree.groupLayer(&grp, 0, name: "그룹")
            grp[1].opacity = 0.5
            let grouped = render(grp)
            grp[1].enabled = false
            let hidden = render(grp)
            let ok = abs(full.0 - 1) < 0.02 && abs(full.1 - 0.2) < 0.02 && filled.0 > 0.6 && filled.0 < 0.8
                && abs(grouped.0 - filled.0) < 0.05 && abs(hidden.0 - 0.2) < 0.02 && grp[0].group == gid
            check("이미지 레이어·칠·그룹 합성", ok,
                  String(format: "가운데 빨강 %.2f (바깥 %.2f), 칠 50%% %.2f, 그룹 불투명도 50%% %.2f, 그룹 끔 %.2f",
                         full.0, full.1, filled.0, grouped.0, hidden.0))

            // 순서 규칙: [A, B, C]에서 B를 묶고 → 위로(그룹 밖) → 아래로(그룹 안 맨 위) → 그룹째 아래로
            var t = ["A", "B", "C"].map { AdjustLayer(name: $0) }
            let g = LayerTree.groupLayer(&t, 1, name: "G")
            func names() -> String { t.map { $0.name + ($0.group == g ? "*" : "") }.joined(separator: " ") }
            let s0 = names()
            LayerTree.moveUp(&t, 1)
            let s1 = names()
            LayerTree.moveDown(&t, t.firstIndex { $0.name == "B" }!)
            let s2 = names()
            LayerTree.moveDown(&t, t.firstIndex { $0.name == "G" }!)
            let s3 = names()
            check("그룹 순서 규칙", s0 == "A B* G C" && s1 == "A G B C" && s2 == "A B* G C" && s3 == "B* G A C",
                  "\(s0) → 위로 \(s1) → 아래로 \(s2) → 그룹째 아래로 \(s3)")
        }

        // 13. 패치: 올가미 안의 얼룩을 옆 자리 결로 채우고, 둘레 밝기에 맞추는가
        do {
            let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
            // 왼쪽→오른쪽으로 밝아지는 바탕 + 가운데 어두운 얼룩
            let ramp = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 400, y: 0),
                "inputColor0": CIColor(red: 0.3, green: 0.3, blue: 0.3), "inputColor1": CIColor(red: 0.7, green: 0.7, blue: 0.7),
            ])!.outputImage!.cropped(to: rect)
            let blob = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 185, y: 135, width: 30, height: 30))
            let cg = Render.context.createCGImage(blob.composited(over: ramp), from: rect, format: .RGBAh, colorSpace: Render.workingSpace)!
            let src = CIImage(cgImage: cg)
            let poly: [Double] = [170, 120, 230, 120, 230, 180, 170, 180]
            // 원본 자리는 위쪽 (같은 밝기 줄)
            let spot = RetouchSpot(kind: .heal, targetX: 170, targetY: 120, sourceX: 170, sourceY: 200, radius: 8,
                                   feather: 0.3, path: poly, patch: true)
            let out = Retouch.apply([spot], to: src, scale: 1)
            func v(_ i: CIImage, _ x: CGFloat, _ y: CGFloat) -> Float {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0]
            }
            let before = v(src, 200, 150), after = v(out, 200, 150), expect = v(src, 200, 100), far = v(out, 50, 50) - v(src, 50, 50)
            check("패치 도구 (얼룩 지우기)", abs(after - expect) < expect * 0.1 && abs(far) < 1e-4,
                  String(format: "얼룩 %.3f → %.3f (둘레 %.3f), 먼 곳 변화 %.5f", before, after, expect, far))
        }

        // 14. 기본 모습 보정표 (카메라 맞춤): 읽기, 1.0 넘는 밝기 보존, Apple 기본이면 그대로
        do {
            let cam = "Canon EOS R5m2"
            let rect = CGRect(x: 0, y: 0, width: 4, height: 1)
            func pix(_ i: CIImage, _ x: CGFloat) -> SIMD3<Float> {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: 0, width: 1, height: 1), format: .RGBAf,
                                      colorSpace: Render.workingSpace)
                return SIMD3(p[0], p[1], p[2])
            }
            func patch(_ v: CGFloat, _ x: CGFloat) -> CIImage {
                CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: Render.workingSpace)!)
                    .cropped(to: CGRect(x: x, y: 0, width: 1, height: 1))
            }
            let src = patch(0.18, 0).composited(over: patch(2.0, 1)).composited(over: patch(0.01, 2)).composited(over: patch(0.6, 3))
            let baked = CIImage(cgImage: Render.context.createCGImage(src, from: rect, format: .RGBAh, colorSpace: Render.workingSpace)!)
            let on = Look.apply(baked, look: 1, camera: cam), off = Look.apply(baked, look: 0, camera: cam)
            let loaded = Look.cube("CanonEOSR5m2")?.n == 33
            let mid = pix(on, 0), hi = pix(on, 1), mid0 = pix(off, 0)
            let one = pix(Look.apply(CIImage(cgImage: Render.context.createCGImage(patch(1.0, 0), from: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                                                    format: .RGBAh, colorSpace: Render.workingSpace)!), look: 1, camera: cam), 0)
            // 보정표가 없는 맥(공개 빌드)에서는 카메라 맞춤을 골라도 Apple 기본 그대로여야 한다
            let pass = loaded
                ? abs(mid0.y - 0.18) < 0.002 && mid.y > 0.05 && mid.y < 0.5 && abs((hi.y - one.y) - 1.0) < 0.02
                    && Look.available(for: cam) && !Look.available(for: "Sony ILCE-7M5")
                : abs(mid.y - mid0.y) < 0.002 && !Look.available(for: cam)
            check("기본 모습 보정표 (카메라 맞춤)", pass,
                  String(format: "읽기 %@, 회색 0.18 → %.3f (끄면 %.3f), 2.0 → %.3f (1.0 → %.3f, 넘친 만큼 보존)", loaded ? "됨" : "안 됨",
                         mid.y, mid0.y, hi.y, one.y))
        }

        // 14-2. 슬라이더 정의 (docs/SLIDERS.md): 밝기는 중간 회색을 스톱 단위로, 대비는 중간 회색 고정,
        //       하이라이트·섀도는 정해진 밝기 구간만 스톱 단위로
        do {
            func gray(_ v: CGFloat, _ edit: (inout DevelopSettings) -> Void) -> Float {
                var st = DevelopSettings()
                edit(&st)
                let r = CGRect(x: 0, y: 0, width: 1, height: 1)
                let img = CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: Render.workingSpace)!).cropped(to: r)
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(Develop.tone(st, img, scale: 1), toBitmap: &p, rowBytes: 16, bounds: r, format: .RGBAf,
                                      colorSpace: Render.workingSpace)
                return p[1]
            }
            let bright = gray(0.18) { $0.brightness = 100 }, brightWhite = gray(1.0) { $0.brightness = 100 }
            let conMid = gray(0.18) { $0.contrast = 60 }, conLo = gray(0.05) { $0.contrast = 60 }, conHi = gray(0.6) { $0.contrast = 60 }
            let brightCon = gray(0.36) { $0.brightness = 0; $0.contrast = 0 }
            let hlMid = gray(0.18) { $0.highlightTone = -100 }, hlTop = gray(0.699) { $0.highlightTone = -100 }
            let hlUp = gray(0.669) { $0.highlightTone = 100 }, hlUpMid = gray(0.18) { $0.highlightTone = 100 }
            let hlOld = gray(0.699) { $0.highlight = 100 }   // 예전 파일 값(0~100 되살림)은 -100과 같다
            // 국소 하이라이트: 밝은 구역의 줄무늬(선형 0.3·0.6)는 눌러도 명암 비율이 그대로여야 한다
            let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1, colorSpace: Render.workingSpace)!,
                "inputColor1": CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1, colorSpace: Render.workingSpace)!,
                "inputWidth": 8, "inputSharpness": 1])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 100))
            func ratio(_ i: CIImage) -> Float {
                var vals: [Float] = []
                for x in stride(from: 180, to: 220, by: 2) {
                    var p = [Float](repeating: 0, count: 4)
                    Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: CGFloat(x), y: 50, width: 1, height: 1),
                                          format: .RGBAf, colorSpace: Render.workingSpace)
                    vals.append(p[1])
                }
                return (vals.max() ?? 1) / max(vals.min() ?? 1, 1e-4)
            }
            var hs = DevelopSettings(); hs.highlightTone = -100
            let r0 = ratio(stripes), rLocal = ratio(Develop.base(hs, to: stripes, guide: nil, scale: 1, haze: 0.9).0),
                rGlobal = ratio(Develop.tone(hs, stripes, scale: 1))
            let shMid = gray(0.18) { $0.shadow = 100 }, shLow = gray(0.00631) { $0.shadow = 100 }
            let ok = abs(bright / 0.36 - 1) < 0.04 && abs(brightWhite - 1) < 0.01
                && abs(conMid / 0.18 - 1) < 0.03 && conLo < 0.05 && conHi > 0.6 && abs(brightCon - 0.36) < 0.004
                && abs(hlMid / 0.18 - 1) < 0.01 && abs(hlTop / 0.3495 - 1) < 0.03 && abs(hlOld - hlTop) < 0.002
                && abs(hlUp / 0.807 - 1) < 0.03 && abs(hlUpMid / 0.18 - 1) < 0.01
                && rLocal / r0 > 0.8 && rGlobal < rLocal * 0.85
                && abs(shMid / 0.18 - 1) < 0.06 && abs(shLow / 0.01262 - 1) < 0.04
            check("슬라이더 정의", ok, String(format:
                "밝기 +100: 회색 0.18 → %.3f (목표 0.36), 흰색 %.3f · 대비 +60: 회색 %.3f, 0.05 → %.3f, 0.6 → %.3f · " +
                "하이라이트 −100: 회색 %.3f, 0.699 → %.3f (목표 0.350) · +100: 0.669 → %.3f (목표 0.807) · " +
                "줄무늬 명암비 %.2f → 국소 %.2f (한 픽셀씩이면 %.2f) · 섀도 100: 회색 %.3f, 0.0063 → %.4f (목표 0.0126)",
                bright, brightWhite, conMid, conLo, conHi, hlMid, hlTop, hlUp, r0, rLocal, rGlobal, shMid, shLow))
        }

        // 15. 색 조정·필터·선택 마스크
        do {
            let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
            func solid(_ v: CGFloat) -> CIImage {
                CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: Render.workingSpace)!).cropped(to: rect)
            }
            func px(_ i: CIImage, _ x: CGFloat, _ y: CGFloat) -> SIMD3<Float> {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                                      colorSpace: Render.workingSpace)
                return SIMD3(p[0], p[1], p[2])
            }
            let mid = solid(0.2140)   // 화면 값 0.5 근처
            var a = LocalAdjust(); a.invert = 1
            let inv = px(Layers.colorAdjust(a, mid), 10, 10).y
            a = LocalAdjust(); a.threshold = 128
            let thLo = px(Layers.colorAdjust(a, solid(0.1)), 10, 10).y, thHi = px(Layers.colorAdjust(a, solid(0.4)), 10, 10).y
            a = LocalAdjust(); a.filterDensity = 100; a.filterHue = 35
            let warm = px(Layers.colorAdjust(a, mid), 10, 10)
            a = LocalAdjust(); a.mixer = [0, 0, 1, 0, 1, 0, 1, 0, 0]
            let swapped = px(Layers.colorAdjust(a, CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1, colorSpace: Render.workingSpace)!).cropped(to: rect)), 5, 5)
            let adjustOK = abs(inv - 0.2140) < 0.03 && thLo < 0.01 && thHi > 0.99 && warm.x > warm.z * 1.3 && abs(swapped.x - 0.1) < 0.01 && abs(swapped.z - 0.8) < 0.01
            check("색 조정 (반전·한계값·포토 필터·채널 혼합)", adjustOK,
                  String(format: "반전 %.3f, 한계값 %.2f/%.2f, 포토 필터 R/B %.2f, 채널 혼합 R %.2f B %.2f", inv, thLo, thHi, warm.x / warm.z, swapped.x, swapped.z))

            // 흐림: 경계가 퍼진다. 하이 패스: 평평한 곳은 0.5
            let edge = solid(0).composited(over: solid(1).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100)))
            let edgeImg = CIImage(cgImage: Render.context.createCGImage(solid(1).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
                .composited(over: solid(0)), from: rect, format: .RGBAh, colorSpace: Render.workingSpace)!)
            _ = edge
            a = LocalAdjust(); a.blur = 6
            let bl = px(Layers.filters(a, edgeImg, scale: 1), 97, 50).y
            a = LocalAdjust(); a.highPass = 4
            let flat = px(Layers.filters(a, edgeImg, scale: 1), 30, 50).y
            check("필터 (흐림·하이 패스)", bl > 0.1 && bl < 0.5 && abs(flat - 0.5) < 0.01,
                  String(format: "경계 옆 %.2f (원래 0), 하이 패스 평평한 곳 %.3f", bl, flat))

            // 선택 마스크: 안은 흰색, 밖은 검정
            let native = CGSize(width: 200, height: 100)
            var m = LayerMask(); m.kind = .rect; m.box = [20, 20, 80, 60]
            let r1 = Layers.maskImage(m, scale: 1, native: native, shape: { i, _ in i }, base: mid)
            m.kind = .ellipse; m.box = [100, 0, 200, 100]
            let e1 = Layers.maskImage(m, scale: 1, native: native, shape: { i, _ in i }, base: mid)
            m.kind = .polygon; m.polygon = [10, 10, 190, 10, 100, 90]
            let p1 = Layers.maskImage(m, scale: 1, native: native, shape: { i, _ in i }, base: mid)
            let selOK = px(r1, 50, 40).x > 0.99 && px(r1, 90, 40).x < 0.01 && px(e1, 150, 50).x > 0.99 && px(e1, 102, 5).x < 0.01
                && px(p1, 100, 30).x > 0.9 && px(p1, 20, 80).x < 0.1
            check("선택 마스크 (사각형·타원·올가미)", selOK,
                  String(format: "사각형 안 %.2f 밖 %.2f, 타원 안 %.2f 모서리 %.2f, 올가미 안 %.2f 밖 %.2f",
                         px(r1, 50, 40).x, px(r1, 90, 40).x, px(e1, 150, 50).x, px(e1, 102, 5).x, px(p1, 100, 30).x, px(p1, 20, 80).x))
        }

        // 16. 교정쇄·색역 경고, 워터마크
        do {
            let r = CGRect(x: 0, y: 0, width: 20, height: 10)
            func px(_ i: CIImage) -> SIMD3<Float> {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBAf,
                                      colorSpace: Render.workingSpace)
                return SIMD3(p[0], p[1], p[2])
            }
            // Rec.2020의 순수 초록은 sRGB 밖, 중간 회색은 안
            let wide = CIImage(color: CIColor(red: 0, green: 0.6, blue: 0, alpha: 1, colorSpace: Render.workingSpace)!).cropped(to: r)
            let gray = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: Render.workingSpace)!).cropped(to: r)
            let w1 = px(Render.softProof(wide, warn: true)), g1 = px(Render.softProof(gray, warn: true)), p1 = px(Render.softProof(wide, warn: false))
            let p2 = px(Render.softProof(CIImage(color: CIColor(red: CGFloat(p1.x), green: CGFloat(p1.y), blue: CGFloat(p1.z), alpha: 1,
                                                                   colorSpace: Render.workingSpace)!).cropped(to: r), warn: false))
            let changed = ((p1 - SIMD3(0, 0.6, 0)) * (p1 - SIMD3(0, 0.6, 0))).sum() > 0.0001
            let stable = ((p2 - p1) * (p2 - p1)).sum() < 0.0001
            check("교정쇄·색역 경고", abs(w1.x - w1.y) < 0.01 && abs(g1.y - 0.2) < 0.005 && changed && stable,
                  String(format: "색역 밖 → 회색 (%.2f,%.2f,%.2f), 회색 그대로 %.3f, 교정쇄 초록 %.2f", w1.x, w1.y, w1.z, g1.y, p1.y))
            var rec = ExportRecipe(); rec.watermark = "© TEST"; rec.watermarkCorner = 1
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 500))
            let marked = Exporter.watermarked(black, rec)
            var buf = [Float](repeating: 0, count: 800 * 500 * 4)
            Render.context.render(marked, toBitmap: &buf, rowBytes: 800 * 16, bounds: black.extent, format: .RGBAf, colorSpace: nil)
            // 비트맵 행 0은 위쪽: 오른쪽 아래 1/4에만 밝은 화소가 있어야 한다
            var br: Float = 0, tl: Float = 0
            for y in 0..<500 { for x in 0..<800 {
                let v = buf[(y * 800 + x) * 4]
                if x > 400 && y > 250 { br = max(br, v) } else if x < 400 && y < 250 { tl = max(tl, v) }
            } }
            check("내보내기 워터마크 (오른쪽 아래)", br > 0.3 && tl < 0.01, String(format: "오른쪽 아래 %.2f, 왼쪽 위 %.2f", br, tl))
        }

        // 17. 캔버스 합성: GPU 커널을 거친 그림을 줄여 바탕 위에 놓아도 여백은 바탕색이어야 한다 (검게 번지던 문제)
        do {
            let src = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
            let processed = Look.apply(src, look: 1, camera: "Canon EOS R5m2")
            let bg = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 500, height: 400))
            let t = CGAffineTransform(a: 0.97, b: 0, c: 0, d: 0.97, tx: 40, ty: 30)
            let out = processed.transformed(by: t).composited(over: bg)
            var p = [Float](repeating: 0, count: 4)
            Render.context.render(out, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let margin = p[0]
            Render.context.render(bg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let bgv = p[0]
            Render.context.render(out, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 200, y: 200, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            // 사진이 포함된 넓은 구역을 한 번에 그릴 때도 (이때만 틀렸다). 뒤에 톤 곡선(화면 색 공간)까지 붙여 본다.
            var ts = DevelopSettings(); ts.contrast = 20
            for (label, img2) in [("커널만", processed), ("커널+톤", Develop.tone(ts, processed, scale: 1))] {
                let o2 = img2.transformed(by: t).composited(over: bg)
                var buf = [Float](repeating: 0, count: 200 * 200 * 4)
                Render.context.render(o2, toBitmap: &buf, rowBytes: 200 * 16, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: .RGBAf, colorSpace: nil)
                let m2 = buf[((199 - 5) * 200 + 5) * 4]
                check("캔버스 여백, 넓게 그리기 (\(label))", abs(m2 - bgv) < 0.005, String(format: "여백 %.4f (바탕 %.4f)", m2, bgv))
            }
            check("캔버스 여백 (GPU 커널 뒤)", abs(margin - bgv) < 0.005, String(format: "여백 %.3f (바탕 %.3f), 사진 %.3f", margin, bgv, p[0]))
        }

        // 18. 리터칭 점: 큰 그림을 먼저 그린 뒤 점 둘레만 다시 그려도 같아야 한다
        //     (Core Image가 미리 계산한 더 큰 입력을 넘겨 커널이 엉뚱한 화소를 읽던 문제 — 점이 검게 칠해졌다)
        do {
            let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
            let ramp = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 600, y: 400),
                "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.05), "inputColor1": CIColor(red: 0.8, green: 0.7, blue: 0.6),
            ])!.outputImage!.cropped(to: rect)
            let base = CIImage(cgImage: Render.context.createCGImage(ramp, from: rect, format: .RGBAh, colorSpace: Render.workingSpace)!)
            let looked = Look.apply(base, look: 1, camera: "Canon EOS R5m2")
            let spot = RetouchSpot(kind: .heal, targetX: 400, targetY: 250, sourceX: 360, sourceY: 250, radius: 20)
            let out = Retouch.apply([spot], to: looked, scale: 1)
            var full = [Float](repeating: 0, count: 600 * 400 * 4)
            Render.context.render(out, toBitmap: &full, rowBytes: 600 * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
            var part = [Float](repeating: 0, count: 4)
            Render.context.render(out, toBitmap: &part, rowBytes: 16, bounds: CGRect(x: 400, y: 250, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let f = full[((399 - 250) * 600 + 400) * 4]
            check("리터칭 점 (부분만 다시 그려도 같음)", abs(part[0] - f) < 0.01 && part[0] > 0.05,
                  String(format: "전체 %.3f, 부분 %.3f", f, part[0]))
        }

        // 7. 조정 레이어: 마스크 종류마다 효과가 맞는 자리에만 나는가
        do {
            let nat = CGSize(width: 1200, height: 800)
            let rect = CGRect(origin: .zero, size: nat)
            // 왼쪽 절반은 어둡고(0.05) 오른쪽 절반은 밝은(0.5) 판
            let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 600, y: 0, width: 600, height: 800))
                .composited(over: CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: rect))
            func px(_ i: CIImage, _ p: CGPoint) -> Float {
                var v = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: nil)
                return v[0]
            }
            func run(_ layer: AdjustLayer, _ geo: DevelopSettings = DevelopSettings()) -> CIImage {
                let shaped = Geometry.crop(geo, Geometry.transform(geo, img, scale: 1))
                return Layers.apply([layer], to: shaped, guide: shaped, scale: 1, guideScale: 1, native: nat,
                                    shape: { m, sc in Geometry.crop(geo, Geometry.transform(geo, m, scale: sc)) })
            }
            // 기준값은 입력 그림에서 잰다 (CIColor는 sRGB라 선형 값과 다르다).
            let hi = px(img, CGPoint(x: 900, y: 400)), lo = px(img, CGPoint(x: 300, y: 400))
            // ① 선형: 위(y=800)가 100%, 아래(y=0)가 0%. 노출 +1 = 선형 값 2배.
            var lin = AdjustLayer(name: "선형")
            lin.adjust.exposure = 1
            lin.mask.kind = .linear
            lin.mask.linear = [900, 780, 900, 20]
            let l = run(lin)
            let top = px(l, CGPoint(x: 900, y: 790)) / hi, bottom = px(l, CGPoint(x: 900, y: 10)) / hi
            check("레이어: 선형 그라디언트", abs(top - 2) < 0.05 && abs(bottom - 1) < 0.02,
                  String(format: "위 %.2f배 (2), 아래 %.2f배 (1)", top, bottom))

            // ② 브러시 + 형태 보정: 원본 (900, 300)에 칠한 점이 회전·키스톤 뒤 제자리에 있는가
            var geo = DevelopSettings()
            geo.rotation = 6; geo.keystoneV = 30
            var br = AdjustLayer(name: "브러시")
            br.adjust.exposure = 1
            br.mask.kind = .brush
            br.mask.strokes = [MaskStroke(points: [900, 300], radius: 30, hardness: 1)]
            let b = run(br, geo)
            let at = Geometry.toDisplay(CGPoint(x: 900, y: 300), geo, native: nat, fullFrame: false)
            let far = Geometry.toDisplay(CGPoint(x: 900, y: 500), geo, native: nat, fullFrame: false)
            let hit = px(b, at) / hi, miss = px(b, far) / hi
            check("레이어: 브러시 마스크가 형태 보정을 따라감", abs(hit - 2) < 0.1 && abs(miss - 1) < 0.02,
                  String(format: "칠한 곳 %.2f배 (2), 먼 곳 %.2f배 (1)", hit, miss))

            // ③ 루마 레인지: 밝은 쪽(오른쪽)만
            var lr = AdjustLayer(name: "루마")
            lr.adjust.exposure = -1
            lr.mask.lumaMin = 0.3; lr.mask.lumaSoft = 0.05   // 밝은 쪽 체감 밝기 0.50, 어두운 쪽 0.08
            let r = run(lr)
            let bright = px(r, CGPoint(x: 900, y: 400)) / hi, dark = px(r, CGPoint(x: 300, y: 400)) / lo
            check("레이어: 루마 레인지", abs(bright - 0.5) < 0.05 && abs(dark - 1) < 0.02,
                  String(format: "밝은 쪽 %.2f배 (0.5), 어두운 쪽 %.2f배 (1)", bright, dark))

            // ④ 불투명도 50% + 반전 원형
            var rad = AdjustLayer(name: "원형")
            rad.adjust.exposure = 1
            rad.opacity = 0.5
            rad.mask.kind = .radial
            rad.mask.radial = [900, 400, 100, 100]
            rad.mask.radialFeather = 0
            rad.mask.invert = true
            let c = run(rad)
            let inside = px(c, CGPoint(x: 900, y: 400)) / hi, outside = px(c, CGPoint(x: 1150, y: 400)) / hi
            // ⑤ 클리핑: 전체 레이어를 원형 레이어에 클리핑하면 원 안에서만
            var base0 = AdjustLayer(name: "원형 0")
            base0.mask.kind = .radial
            base0.mask.radial = [900, 400, 100, 100]
            base0.mask.radialFeather = 0
            var clip = AdjustLayer(name: "클리핑")
            clip.adjust.exposure = 1
            clip.clipped = true
            let shapedImg = Geometry.crop(DevelopSettings(), Geometry.transform(DevelopSettings(), img, scale: 1))
            let cl = Layers.apply([base0, clip], to: shapedImg, guide: shapedImg, scale: 1, guideScale: 1, native: nat,
                                  shape: { m, sc in Geometry.crop(DevelopSettings(), Geometry.transform(DevelopSettings(), m, scale: sc)) })
            let cin = px(cl, CGPoint(x: 900, y: 400)) / hi, cout = px(cl, CGPoint(x: 1150, y: 400)) / hi
            check("레이어: 클리핑 마스크", abs(cin - 2) < 0.05 && abs(cout - 1) < 0.02,
                  String(format: "아래 레이어 원 안 %.2f배 (2), 밖 %.2f배 (1)", cin, cout))

            // ⑥ 디졸브 50%: 바뀐 픽셀이 절반쯤, 바뀐 픽셀은 100% 효과
            var dis = AdjustLayer(name: "디졸브")
            dis.adjust.exposure = 1
            dis.blend = "dissolve"
            dis.opacity = 0.5
            let dd = run(dis)
            var dv = [Float](repeating: 0, count: 200 * 100 * 4)
            Render.context.render(dd, toBitmap: &dv, rowBytes: 200 * 16, bounds: CGRect(x: 700, y: 300, width: 200, height: 100),
                                  format: .RGBAf, colorSpace: nil)
            var changed = 0, full = 0
            for i in stride(from: 0, to: dv.count, by: 4) {
                let k = dv[i] / hi
                if k > 1.05 { changed += 1; if abs(k - 2) < 0.05 { full += 1 } }
            }
            let frac = Double(changed) / 20000
            check("레이어: 디졸브", abs(frac - 0.5) < 0.05 && full == changed,
                  String(format: "바뀐 픽셀 %.1f%% (50%%), 그중 100%% 효과 %d/%d", frac * 100, full, changed))

            // ⑦ 하드 혼합: 결과는 0 또는 1뿐
            var hm = AdjustLayer(name: "하드 혼합")
            hm.blend = "hardMix"
            let h = run(hm)
            let hv = [px(h, CGPoint(x: 900, y: 400)), px(h, CGPoint(x: 300, y: 400))]
            check("레이어: 하드 혼합", hv.allSatisfy { abs($0) < 0.001 || abs($0 - 1) < 0.001 },
                  String(format: "밝은 쪽 %.2f, 어두운 쪽 %.2f (0 또는 1)", hv[0], hv[1]))

            // ⑧ Lab: 흰색 L100 a0 b0, P3 순수 빨강은 a가 크게 양수
            let white = InspectorViewController.lab([255, 255, 255]), redLab = InspectorViewController.lab([255, 0, 0])
            check("색 측정기 Lab", abs(white.0 - 100) < 0.5 && abs(white.1) < 0.5 && abs(white.2) < 0.5 && redLab.1 > 70,
                  String(format: "흰색 L %.1f a %.1f b %.1f · 빨강 a %.0f", white.0, white.1, white.2, redLab.1))

            check("레이어: 반전 원형 + 불투명도", abs(inside - 1) < 0.02 && abs(outside - 1.5) < 0.05,
                  String(format: "원 안 %.2f배 (1), 원 밖 %.2f배 (1.5)", inside, outside))
        }

        // 5. 복구 브러시: 결 있는 기울기 위의 어두운 얼룩을 지우면 얼룩 없는 원래 그림에 가까워지는가
        do {
            let size = CGRect(x: 0, y: 0, width: 600, height: 600)
            let grad = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 600, y: 600),
                "inputColor0": CIColor(red: 0.15, green: 0.12, blue: 0.1), "inputColor1": CIColor(red: 0.6, green: 0.55, blue: 0.5),
            ])!.outputImage!.cropped(to: size)
            // 결: 0.85~1.15 배율의 난수를 곱한다 (알파 1 유지). 더하기 합성은 알파까지 더해져서 쓰지 않는다.
            let texture = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: size)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0.3, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.85, y: 0.85, z: 0.85, w: 1),
                ])
            let cleanLive = texture.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: grad]).cropped(to: size)
            let stain = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 300, y: 300), "inputRadius0": 14, "inputRadius1": 20,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.85), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])!.outputImage!.cropped(to: size)
            // 난수 생성 필터는 사용자 GPU 커널을 거칠 때마다 다른 무늬가 나온다. 픽셀로 굳혀 둔다.
            func bake(_ i: CIImage) -> CIImage {
                let cg = Render.context.createCGImage(i, from: size, format: .RGBAh, colorSpace: Render.workingSpace)!
                return CIImage(cgImage: cg)
            }
            let clean = bake(cleanLive)
            let dirty = bake(stain.composited(over: clean))
            func meanDiff(_ a: CIImage, _ b: CIImage, _ r: CGRect) -> Double {
                let w = Int(r.width), h = Int(r.height)
                var pa = [Float](repeating: 0, count: w * h * 4), pb = pa
                Render.context.render(a, toBitmap: &pa, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
                Render.context.render(b, toBitmap: &pb, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
                var sum = 0.0
                for i in stride(from: 0, to: pa.count, by: 4) { for c in 0..<3 { sum += Double(abs(pa[i + c] - pb[i + c])) } }
                return sum / Double(w * h * 3)
            }
            // 결은 원본 자리마다 다르므로 픽셀 단위 비교는 뜻이 없다. 살짝 흐려서 얼룩과 밝기만 비교하고,
            // 결이 살아 있는지는 표준편차로 따로 본다.
            let spotBox = CGRect(x: 280, y: 280, width: 40, height: 40)
            func low(_ i: CIImage) -> CIImage { i.blurred(3) }
            func grainStd(_ i: CIImage) -> Double {
                let w = 40, h = 40
                // 고주파 = 원본 − 흐림
                var a = [Float](repeating: 0, count: w * h * 4), b = a
                Render.context.render(i, toBitmap: &a, rowBytes: w * 16, bounds: spotBox, format: .RGBAf, colorSpace: nil)
                Render.context.render(low(i), toBitmap: &b, rowBytes: w * 16, bounds: spotBox, format: .RGBAf, colorSpace: nil)
                var ss = 0.0
                for k in stride(from: 0, to: a.count, by: 4) { let d = Double(a[k] - b[k]); ss += d * d }
                return (ss / Double(w * h)).squareRoot()
            }
            let before = meanDiff(low(dirty), low(clean), spotBox)
            let src = Retouch.pickSource(target: CGPoint(x: 300, y: 300), radius: 24, in: dirty, scale: 1)
            var heal = RetouchSpot(targetX: 300, targetY: 300, sourceX: src.x, sourceY: src.y, radius: 24)
            let healed = Retouch.apply([heal], to: dirty, scale: 1)
            let after = meanDiff(low(healed), low(clean), spotBox)
            heal.kind = .clone
            let cloned = Retouch.apply([heal], to: dirty, scale: 1)
            let afterClone = meanDiff(low(cloned), low(clean), spotBox)
            // 멀리 떨어진 곳은 그대로여야 한다.
            let untouched = meanDiff(healed, dirty, CGRect(x: 20, y: 20, width: 60, height: 60))
            let tClean = grainStd(clean), tHealed = grainStd(healed)
            // 진단: 불투명도 0 복제는 원래 그림과 같아야 한다.
            var zero = heal; zero.opacity = 0
            let ident = Retouch.apply([zero], to: dirty, scale: 1)
            print(String(format: "진단: 불투명도 0 복제 변화 %.6f", meanDiff(ident, dirty, CGRect(x: 250, y: 250, width: 100, height: 100))))
            do {
                let r = CGRect(x: 250, y: 250, width: 100, height: 100)
                var pa = [Float](repeating: 0, count: 100 * 100 * 4), pb = pa
                Render.context.render(ident, toBitmap: &pa, rowBytes: 1600, bounds: r, format: .RGBAf, colorSpace: nil)
                Render.context.render(dirty, toBitmap: &pb, rowBytes: 1600, bounds: r, format: .RGBAf, colorSpace: nil)
                var worst: [(Float, Int)] = []
                for i in stride(from: 0, to: pa.count, by: 4) { worst.append((abs(pa[i] - pb[i]), i / 4)) }
                worst.sort { $0.0 > $1.0 }
                let big = worst.filter { $0.0 > 0.01 }.count
                print("진단: 차 > 0.01 픽셀 \(big)/10000, 예:", worst.prefix(4).map { String(format: "#%d %.3f vs %.3f (a %.2f/%.2f)", $0.1, pa[$0.1 * 4], pb[$0.1 * 4], pa[$0.1 * 4 + 3], pb[$0.1 * 4 + 3]) })
            }
            let shiftedDbg = dirty.clampedToExtent().transformed(by: .init(translationX: 300 - src.x, y: 300 - src.y)).cropped(to: size)
            if let dir = ProcessInfo.processInfo.environment["DUOCHROME_DUMP"] {
                for (name, im) in [("clean", clean), ("dirty", dirty), ("healed", healed), ("cloned", cloned), ("shifted", shiftedDbg), ("ident", ident)] {
                    try? Render.context.writePNGRepresentation(of: im.cropped(to: CGRect(x: 200, y: 180, width: 240, height: 200)),
                        to: URL(fileURLWithPath: "\(dir)/\(name).png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
            }
            check("복구 브러시", after < before * 0.2 && untouched < 1e-4 && abs(tHealed - tClean) < tClean * 0.35,
                  String(format: "얼룩(흐림 비교) %.4f → 복구 %.4f, 복제 %.4f · 결 %.4f → %.4f · 원본 자리 (%.0f,%.0f) · 먼 곳 변화 %.6f",
                         before, after, afterClone, tClean, tHealed, src.x, src.y, untouched))
        }

        // 4. 진단: 실제 사진에서 뽑은 선 (DUOCHROME_DIAG_LINES)
        if let spec = ProcessInfo.processInfo.environment["DUOCHROME_DIAG_LINES"] {
            let real = spec.split(separator: ";").map { l -> (CGPoint, CGPoint) in
                let v = l.split(separator: ",").compactMap { Double($0) }
                return (CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]))
            }
            let r = Geometry.solveVerticals(real, current, native: native, fullFrame: true)
            print(String(format: "진단: 풀이 세로 %.2f 회전 %.2f", r.keystoneV, r.rotation))
            for (v, rot) in [(r.keystoneV, r.rotation), (0, 0), (20, 0), (30, 0), (40, 0), (30, 0.5)] as [(Float, Float)] {
                var t = current; t.keystoneV = v; t.rotation = rot
                let angles = real.map { l -> Double in
                    let a = Geometry.toDisplay(Geometry.fromDisplay(l.0, current, native: native, fullFrame: true), t, native: native, fullFrame: true)
                    let b = Geometry.toDisplay(Geometry.fromDisplay(l.1, current, native: native, fullFrame: true), t, native: native, fullFrame: true)
                    return atan2(Double(b.x - a.x), Double(b.y - a.y)) * 180 / .pi
                }
                print(String(format: "  세로 %6.2f 회전 %5.2f → 선 각도 %@", v, rot, angles.map { String(format: "%.2f°", $0) }.joined(separator: ", ")))
            }
        }

        // 19. 레이어 효과 전부: 영역이 그대로, 값이 유한, 대부분은 그림을 바꾼다 (Effects.swift)
        do {
            let e = CGRect(x: 0, y: 0, width: 200, height: 150)
            let base = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputColor0": CIColor(red: 0.05, green: 0.2, blue: 0.6),
                "inputPoint1": CIVector(x: 200, y: 150), "inputColor1": CIColor(red: 0.9, green: 0.6, blue: 0.1)])!.outputImage!
                .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: CIImage.empty()])
                .cropped(to: e)
            let spot = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: 70, y: 80), "inputRadius0": 10, "inputRadius1": 30,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!.cropped(to: e)
            // 결이 있어야 흐림·선명·중간값이 티가 난다: 잡음과 딱딱한 줄무늬를 섞는다
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.25, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.25, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.25, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: e)
            let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0), "inputColor1": CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
                kCIInputWidthKey: 7, kCIInputSharpnessKey: 1])!.outputImage!.cropped(to: e)
            let img = spot.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey:
                stripes.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey:
                    noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: base])])])
            func pixels(_ i: CIImage) -> [Float] {
                var b = [Float](repeating: 0, count: 200 * 150 * 4)
                Render.context.render(i, toBitmap: &b, rowBytes: 200 * 16, bounds: e, format: .RGBAf, colorSpace: Render.workingSpace)
                return b
            }
            let p0 = pixels(img)
            var bad: [String] = [], same: [String] = []
            var slow: [String] = []
            for spec in Effects.all {
                let fx = LayerEffect(kind: spec.kind)
                let t0 = CACurrentMediaTime()
                let out = Effects.apply([fx], img, scale: 1)
                let p = pixels(out)
                let ms = (CACurrentMediaTime() - t0) * 1000
                if ms > 1500 { slow.append("\(spec.title) \(Int(ms))ms") }
                if out.extent != e || p.contains(where: { !$0.isFinite }) { bad.append(spec.title); continue }
                let diff = zip(p, p0).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(p.count)
                if diff < 0.0005 { same.append(spec.title) }
            }
            // 기본값이 "아무것도 안 함"인 것 (선택 색상·사용자 정의는 값을 줘야 바뀐다)
            let allowedSame: Set<String> = ["선택 색상", "카메라 로우 필터"]
            let kernels: [(String, Any?)] = [("twirl", Effects.twirlK), ("ripple", Effects.rippleK), ("zigzag", Effects.zigzagK),
                ("polar", Effects.polarK), ("diffuse", Effects.diffuseK), ("spin", Effects.spinK), ("kuwahara", Effects.kuwaharaK),
                ("bilateral", Effects.bilateralK), ("selective", Effects.selectiveK), ("thresholdMix", Effects.thresholdMixK),
                ("divide", Effects.divideK), ("multiply", Effects.multiplyK), ("lighten", Effects.lightenK), ("mezzo", Effects.mezzoK)]
            let missing = kernels.filter { $0.1 == nil }.map(\.0)
            check("효과 커널 컴파일", missing.isEmpty, missing.isEmpty ? "\(kernels.count)개" : "실패 \(missing)")
            let realSame = same.filter { !allowedSame.contains($0) }
            check("레이어 효과 \(Effects.all.count)가지", bad.isEmpty && realSame.isEmpty,
                  "망가짐 \(bad), 안 바뀜 \(realSame), 느림 \(slow)")
        }

        // 20. 레이어 스타일 10가지: 네모 하나에 하나씩 켜고, 바깥에 생기는 것(그림자·광선·바깥 획)과 안에서 바뀌는 것을 확인
        do {
            let e = CGRect(x: 0, y: 0, width: 200, height: 200)
            let square = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.3)).cropped(to: CGRect(x: 60, y: 60, width: 80, height: 80))
                .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e)]).cropped(to: e)
            func px(_ i: CIImage, _ x: Int, _ y: Int) -> [Float] {
                var b = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: Render.workingSpace)
                return b
            }
            let inside0 = px(square, 100, 100)
            var fails: [String] = []
            func test(_ name: String, outside: Bool, _ f: (inout LayerStyles) -> Void) {
                var st = LayerStyles()
                f(&st)
                let out = LayerStyles.apply(st, square, scale: 1)
                let o = px(out, 100, 100), far = px(out, 5, 5)
                if out.extent != e || o.contains(where: { !$0.isFinite }) { fails.append("\(name) 망가짐"); return }
                if far[3] > 0.01 { fails.append("\(name) 먼 곳에 번짐") }
                if outside {
                    // 네모 바로 바깥(오른쪽 아래, 그림자 방향)에 뭔가 생겨야
                    let edge = px(out, 150, 52)
                    if edge[3] < 0.02 { fails.append("\(name) 바깥 없음") }
                } else {
                    let d = zip(o, inside0).map { abs($0 - $1) }.reduce(0, +)
                    let edgeIn = px(out, 63, 100), edgeIn0 = px(square, 63, 100)
                    let de = zip(edgeIn, edgeIn0).map { abs($0 - $1) }.reduce(0, +)
                    if d + de < 0.01 { fails.append("\(name) 안 바뀜") }
                }
            }
            test("그림자", outside: true) { $0.dropShadow.enabled = true; $0.dropShadow.angle = 135 }
            test("외부 광선", outside: true) { $0.outerGlow.enabled = true }
            test("바깥 획", outside: true) { $0.stroke.enabled = true; $0.stroke.size = 20 }
            test("안쪽 획", outside: false) { $0.stroke.enabled = true; $0.stroke.position = 1 }
            test("내부 그림자", outside: false) { $0.innerShadow.enabled = true }
            test("내부 광선", outside: false) { $0.innerGlow.enabled = true }
            test("경사와 엠보스", outside: false) { $0.bevel.enabled = true }
            test("새틴", outside: false) { $0.satin.enabled = true }
            test("색상 오버레이", outside: false) { $0.colorOverlay.enabled = true }
            test("그라디언트 오버레이", outside: false) { $0.gradientOverlay.enabled = true }
            for p in 0..<4 { test("패턴 \(p)", outside: false) { $0.patternOverlay.enabled = true; $0.patternOverlay.pattern = p; $0.patternOverlay.scale = 7 } }
            if let dir = ProcessInfo.processInfo.environment["DUOCHROME_STYLE_DUMP"] {
                let ell = CIImage(color: CIColor(red: 0.9, green: 0.45, blue: 0.1)).cropped(to: e)
                    .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
                        "inputMaskImage": CIFilter(name: "CIRadialGradient", parameters: [kCIInputCenterKey: CIVector(x: 100, y: 100),
                            "inputRadius0": 55, "inputRadius1": 56, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: e)])
                let bg = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: e)
                for (name, f) in [("shadow", { (s: inout LayerStyles) in s.dropShadow.enabled = true }),
                                  ("bevel", { (s: inout LayerStyles) in s.bevel.enabled = true }),
                                  ("stroke", { (s: inout LayerStyles) in s.stroke.enabled = true })] as [(String, (inout LayerStyles) -> Void)] {
                    var st = LayerStyles(); f(&st)
                    let out = LayerStyles.apply(st, ell, scale: 1).applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: bg])
                    try? Render.context.writePNGRepresentation(of: out, to: URL(fileURLWithPath: dir + "/\(name).png"), format: .RGBA8, colorSpace: Render.displaySpace)
                }
            }
            check("레이어 스타일", fails.isEmpty, fails.isEmpty ? "10가지 (패턴 4종)" : "\(fails)")
        }

        // 21. PSD 가져오기: 파일을 우리 방식으로 다시 그려 파일에 든 합친 그림과 비교한다
        do {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tests/Fixtures/psd")
            func compare(_ name: String) -> (Float, Int, [String])? {
                let url = dir.appendingPathComponent(name)
                guard let f = try? PSD.read(url), let doc = try? RawDocument(url: url) else { return nil }
                let res = PSDImport.convert(f)
                doc.settings.layers = res.layers
                doc.settings.gammaBlend = true
                if let k = ProcessInfo.processInfo.environment["DUOCHROME_PSD_ONLY"].flatMap(Int.init), name.hasPrefix("struct") {
                    doc.settings.layers = Array(doc.settings.layers.prefix(k))
                    print("레이어:", doc.settings.layers.map { "\($0.name)[\($0.kind) \($0.blend) op\($0.opacity) fill\($0.fill) grp\($0.group?.prefix(4) ?? "-")]" })
                }
                let img = doc.image(scale: 1)
                let w = f.width, h = f.height
                var ours = [UInt8](repeating: 0, count: w * h * 4)
                Render.context.render(img, toBitmap: &ours, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                let m = PSD.mergedChannels(f)
                guard m.count >= 3 else { return nil }
                let bps = max(f.depth / 8, 1)
                if let d = ProcessInfo.processInfo.environment["DUOCHROME_PSD_DUMP"] {
                    try? Render.context.writePNGRepresentation(of: img, to: URL(fileURLWithPath: d + "/\(name)-ours.png"), format: .RGBA8,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    if let cg = PSDImport.mergedImage(f) { try? Render.context.writePNGRepresentation(of: CIImage(cgImage: cg), to: URL(fileURLWithPath: d + "/\(name)-merged.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
                }
                var sum: Float = 0
                for y in 0 ..< h { for x in 0 ..< w {
                    let i = y * w + x
                    // 그림은 아래 줄부터가 아니라 위 줄부터 (render는 위가 0인 비트맵)
                    for c in 0 ..< 3 { sum += abs(Float(ours[i * 4 + c]) - Float(m[c][i * bps])) }
                } }
                return (sum / Float(w * h * 3), res.layers.count, res.notes)
            }
            var worstAdj: (String, Float) = ("", 0)
            var adjFails: [String] = []
            for n in ["levels", "curves", "huesat", "colorize", "brightness", "invert", "posterize", "threshold", "colorbalance",
                      "selective", "mixer", "gradmap", "exposure", "vibrance", "bw"] {
                guard let (e, _, _) = compare("adj-\(n).psd") else { adjFails.append(n + " 못 읽음"); continue }
                if e > worstAdj.1 { worstAdj = (n, e) }
                if e > (["colorbalance", "vibrance"].contains(n) ? 12 : 3) { adjFails.append(String(format: "%@ %.1f", n, e)) }
            }
            check("PSD 조정 레이어 15종", adjFails.isEmpty, adjFails.isEmpty ? String(format: "가장 큰 평균 차이 %@ %.2f/255", worstAdj.0, worstAdj.1) : "\(adjFails)")
            for n in ["struct8.psd", "struct16.psd", "struct8b.psb"] {
                guard let (e, count, notes) = compare(n) else { check("PSD 구조 \(n)", false, "못 읽음"); continue }
                check("PSD 구조 \(n)", e < 4 && count == 7, String(format: "레이어 %d개, 평균 차이 %.2f/255 %@", count, e, notes.joined(separator: ",")))
            }
        }

        // 22. PSD 쓰기: 가져온 문서를 다시 PSD·16비트·PSB로 쓰고 우리 해독기로 읽어 합친 그림·레이어를 본다
        do {
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tests/Fixtures")
            let src = fixtures.appendingPathComponent("psd/struct8.psd")
            if let f = try? PSD.read(src), let doc = try? RawDocument(url: src) {
                var st = doc.settings
                st.layers = PSDImport.convert(f).layers
                st.gammaBlend = true
                doc.settings = st
                let ref = PSD.mergedChannels(f)
                for (name, depth, psb) in [("out8.psd", 8, false), ("out16.psd", 16, false), ("out8.psb", 8, true)] {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-" + name)
                    do {
                        try PSDExport.write(doc, to: url, options: .init(depth: depth, psb: psb))
                        let back = try PSD.read(url)
                        let m = PSD.mergedChannels(back)
                        let bps = depth / 8
                        var sum: Float = 0
                        for i in 0 ..< back.width * back.height { for c in 0 ..< 3 { sum += abs(Float(m[c][i * bps]) - Float(ref[c][i])) } }
                        let e = sum / Float(back.width * back.height * 3)
                        let names = back.layers.map(\.unicodeName)
                        let groups = back.layers.filter { $0.section != nil }.count
                        let adj = back.layers.filter { $0.block("hue2") != nil }.count
                        // 레이어 하나씩 다시 읽어 합쳐도 되는가 (배경 + 픽셀 레이어)
                        let pixelOK = back.layers.filter { $0.width > 0 }.allSatisfy { PSDImport.layerImage($0, back) != nil }
                        check("PSD 쓰기 \(name)", e < 3 && back.layers.count == 9 && groups == 2 && adj == 1 && pixelOK && back.depth == depth && back.isPSB == psb,
                              String(format: "레이어 %d개 (그룹 표시 %d, 조정 %d), 합친 그림 차이 %.2f/255 %@", back.layers.count, groups, adj, e, names.joined(separator: "·")))
                    } catch { check("PSD 쓰기 \(name)", false, "\(error)") }
                }

                // 23. LUT 내보내기: 조정 없으면 그대로, 노출 +1이면 가운데가 밝아진다
                st.layers = []
                doc.settings = st
                func lutValue(_ text: String, _ r: Int, _ g: Int, _ b: Int, n: Int = 33) -> [Float] {
                    let rows = text.split(separator: "\n").filter { $0.first.map { $0.isNumber || $0 == "-" } ?? false }
                    return rows[b * n * n + g * n + r].split(separator: " ").compactMap { Float($0) }
                }
                if let id = LUTExport.cube(doc) {
                    let a = lutValue(id, 16, 8, 24), b0 = lutValue(id, 0, 32, 0)
                    let okId = abs(a[0] - 0.5) < 0.01 && abs(a[1] - 0.25) < 0.01 && abs(a[2] - 0.75) < 0.01 && abs(b0[1] - 1) < 0.01
                    var ex = st; ex.exposure += 1; doc.settings = ex
                    let brighter = LUTExport.cube(doc).map { lutValue($0, 16, 16, 16)[0] } ?? 0
                    check("LUT 내보내기", okId && brighter > 0.62, String(format: "그대로 (%.3f %.3f %.3f), 노출 +1 가운데 0.5 → %.3f", a[0], a[1], a[2], brighter))
                    doc.settings = st
                }

                // 24. DNG 저장: 다시 열어 (맥 RAW 해독기) 평균 색이 비슷한가
                let dng = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test.dng")
                do {
                    try DNGWriter.write(doc, to: dng)
                    let raw = CIRAWFilter(imageURL: dng)
                    let back = raw?.outputImage
                    func mean(_ i: CIImage) -> [Float] {
                        var p = [Float](repeating: 0, count: 4)
                        let avg = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)])
                        Render.context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        return p
                    }
                    let m0 = mean(doc.image(scale: 1)), m1 = back.map(mean) ?? [0, 0, 0, 0]
                    let d = zip(m0.prefix(3), m1.prefix(3)).map { abs($0 - $1) }.max() ?? 1
                    check("DNG 저장", back != nil && back!.extent.width == doc.image(scale: 1).extent.width && d < 0.08,
                          String(format: "크기 %@, 평균 색 %.3f %.3f %.3f → %.3f %.3f %.3f", "\(back?.extent.size ?? .zero)", m0[0], m0[1], m0[2], m1[0], m1[1], m1[2]))
                } catch { check("DNG 저장", false, "\(error)") }
            }

            // 25. 세션 사이드카·스타일 (sidecar 폴더의 .cos 하나)
            let cosFile = (try? FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("sidecar"), includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "cos" }
            if let cosFile, let d = try? Data(contentsOf: cosFile) {
                let p = SidecarImport.parse(d)
                let dict = CatalogImport.convert(SidecarImport.columns(p.values), orientation: 1)
                let clarity = dict["clarity"] as? Double ?? 0, contrast = dict["contrast"] as? Double ?? 0
                check("세션 사이드카 .cos", p.rating == 5 && p.color == 1 && abs(clarity - 26.11) < 0.1 && abs(contrast - 20.19) < 0.1
                      && dict["highlights"] != nil && (dict["color"] as? [String: Any])?["high"] != nil,
                      "별점 \(p.rating ?? -1)·색 \(p.color ?? -1)·클래리티 \(clarity)·대비 \(contrast)·키 \(dict.keys.sorted())")
            }
            if let d = try? Data(contentsOf: fixtures.appendingPathComponent("sidecar/Cool Tones.costyle")) {
                let p = SidecarImport.parse(d)
                let dict = CatalogImport.convert(SidecarImport.columns(p.values), orientation: 1)
                check("스타일 .costyle", p.name == "Cool Tones" && abs((dict["saturation"] as? Double ?? 0) + 10.3) < 0.1 && (dict["color"] as? [String: Any])?["mid"] != nil,
                      "\(p.name ?? "?"): \(dict.keys.sorted())")
            }

            // 26. 프리셋 파일 (DUOCHROME_PRESET_DIR 폴더의 파일로)
            if let presetDir = ProcessInfo.processInfo.environment["DUOCHROME_PRESET_DIR"] {
                let presets = URL(fileURLWithPath: presetDir)
                let aco = (try? PresetFiles.readACO(Data(contentsOf: presets.appendingPathComponent("Web Hues.aco")))) ?? []
                let grd = (try? PresetFiles.readGRD(Data(contentsOf: presets.appendingPathComponent("Default Gradients.grd")))) ?? []
                let pat = (try? PresetFiles.readPAT(Data(contentsOf: presets.appendingPathComponent("Rock Patterns.pat")), prefix: "암석")) ?? []
                let abr = (try? PresetFiles.readABR(Data(contentsOf: presets.appendingPathComponent("Legacy Brushes.abr")), prefix: "레거시")) ?? []
                let tipsOK = abr.prefix(5).allSatisfy { PresetFiles.tip($0.file) != nil }
                let patOK = pat.first.map { FileManager.default.fileExists(atPath: PresetFiles.url($0.file).path) } ?? false
                check("프리셋 파일", aco.count > 100 && grd.count > 5 && pat.count > 3 && abr.count > 10 && tipsOK && patOK,
                      "견본 \(aco.count) (첫 색 \(aco.first?.rgb ?? [])), 그라디언트 \(grd.count) (\(grd.first?.name ?? "")), 패턴 \(pat.count) (\(pat.first.map { "\($0.name) \($0.width)×\($0.height)" } ?? "")), 브러시 \(abr.count) (\(abr.first.map { "\($0.width)×\($0.height)" } ?? ""))")
                if let dir = ProcessInfo.processInfo.environment["DUOCHROME_PSD_DUMP"] {
                    for b in abr.prefix(6) { try? FileManager.default.copyItem(at: PresetFiles.url(b.file), to: URL(fileURLWithPath: dir + "/brush-\(b.name).png")) }
                    for p in pat.prefix(3) { try? FileManager.default.copyItem(at: PresetFiles.url(p.file), to: URL(fileURLWithPath: dir + "/pat-\(p.name).png")) }
                }
            }
        }

        // 27~33. 사진 관리 (임시 카탈로그·임시 폴더)
        do {
            let fm = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-b-\(UUID().uuidString)")
            let src = root.appendingPathComponent("card"), other = root.appendingPathComponent("moved")
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            try? fm.createDirectory(at: other, withIntermediateDirectories: true)
            // 작은 JPEG 네 장 (색이 다르게)
            for (i, c) in [(0.8, 0.2, 0.2), (0.2, 0.7, 0.3), (0.3, 0.3, 0.8), (0.5, 0.5, 0.5)].enumerated() {
                let img = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
                try? Render.context.writeJPEGRepresentation(of: img, to: src.appendingPathComponent("IMG_\(i + 1).jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            if let cat = try? Catalog(url: root.appendingPathComponent("t.duochromecatalog")) {
                let lib = Library(catalog: cat)
                // 불러오기: 복사 + 이름 규칙 + 날짜 폴더 + 백업
                var o = PhotoImporter.Options(source: src)
                o.mode = .copy; o.destination = root.appendingPathComponent("lib"); o.backup = root.appendingPathComponent("backup")
                o.namePattern = "사진_{번호}"; o.dateFolders = true
                let res = PhotoImporter.run(o, catalog: cat)
                lib.show(.recentImport)
                let backups = (fm.enumerator(atPath: root.appendingPathComponent("backup").path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jpg") }
                check("불러오기 (복사·이름·날짜 폴더·백업)", res.imported.count == 4 && lib.items.count == 4 && backups.count == 4
                      && lib.items.allSatisfy { $0.name.hasPrefix("사진_00") } && res.imported.allSatisfy { $0.deletingLastPathComponent().lastPathComponent.contains("-") },
                      "불러옴 \(res.imported.count), 목록 \(lib.items.map(\.name)), 백업 \(backups.count), 폴더 \(res.imported.first?.deletingLastPathComponent().lastPathComponent ?? "")")
                let items = lib.items
                // 채택·거부, 키워드 계층, 메타데이터
                try? cat.setFlag([items[0].id, items[1].id], 1)
                try? cat.setFlag([items[3].id], -1)
                lib.setRating([items[0], items[2]], 4)
                try? cat.addKeywords([items[0].id, items[2].id], ["장소>서울>종로", "건물"])
                try? cat.addKeywords([items[1].id], ["장소>부산"])
                try? cat.setMetadata([items[0].id], "title", "시험 제목")
                let place = cat.allKeywords().first { $0.name == "장소" && $0.parent == nil }
                let nPlace = place.map { (try? cat.count(.keyword($0.id))) ?? 0 } ?? 0
                check("채택·거부·키워드 계층", (try? cat.count(.flag(1))) == 2 && (try? cat.count(.flag(-1))) == 1 && nPlace == 3
                      && cat.keywords(of: items[0].id).map(\.1).contains("장소>서울>종로"),
                      "채택 \((try? cat.count(.flag(1))) ?? -1), 거부 \((try? cat.count(.flag(-1))) ?? -1), 장소 아래 \(nPlace)장, \(cat.keywords(of: items[0].id).map(\.1))")
                // 스마트 앨범
                var rule = Catalog.SmartRule(); rule.minRating = 4; rule.keyword = "종로"; rule.flag = 2
                let sa = (try? cat.addSmartAlbum("시험", rule: rule)) ?? 0
                let smartIDs = ((try? cat.items(.album(sa))) ?? []).map(\.id)
                // 검색
                let s1 = cat.searchIDs(["키워드:서울", "채택"]) ?? []
                let s2 = cat.searchIDs(["제목:시험"]) ?? []
                check("스마트 앨범·검색", Set(smartIDs) == [items[0].id, items[2].id] && s1 == [items[0].id] && s2 == [items[0].id],
                      "스마트 \(smartIDs.count)장, 키워드+채택 \(s1.count)장, 제목 \(s2.count)장")
                // 변형본: 같은 파일, 다른 조정 열쇠
                let v = try? cat.addVariant(of: items[0].id)
                lib.saveRawSettings(["exposure": 1.0], for: items[0].url)
                if let v { lib.saveRawSettings(["exposure": -1.0], for: v) }
                let vdoc = v.flatMap { try? RawDocument(url: $0) }
                let e0 = lib.loadSettings(for: items[0].url, over: DevelopSettings())?.exposure ?? 0
                let e1 = v.flatMap { lib.loadSettings(for: $0, over: DevelopSettings())?.exposure } ?? 0
                lib.show(.all)
                check("변형본", v?.fragment == "v2" && vdoc != nil && e0 == 1 && e1 == -1 && lib.items.count == 5 && lib.items.contains { $0.variant == 2 },
                      "조각 \(v?.fragment ?? "-"), 열기 \(vdoc != nil), 노출 \(e0)/\(e1), 목록 \(lib.items.count)장")
                // 이름 바꾸기 규칙 + 경로 옮기기 (조정값·변형본이 따라온다)
                let newName = MainWindowController.renamed("{날짜}_{이름}_{번호4}", item: items[0], index: 7, date: Date(timeIntervalSince1970: 0), camera: "EOS R5")
                let oldURL = URL(fileURLWithPath: items[0].url.path)
                let newURL = other.appendingPathComponent(newName + ".jpg")
                try? fm.moveItem(at: oldURL, to: newURL)
                try? cat.movePath(from: oldURL, to: newURL)
                lib.show(.all)
                let moved = lib.items.first { $0.url.path == newURL.path && $0.variant == 0 }
                let mv = lib.items.first { $0.url.path == newURL.path && $0.variant == 2 }
                check("이름 바꾸기·경로 옮기기", newName.hasSuffix("_0007") && moved != nil && mv != nil
                      && lib.loadSettings(for: newURL, over: DevelopSettings())?.exposure == 1 && mv.flatMap { lib.loadSettings(for: $0.url, over: DevelopSettings())?.exposure } == -1,
                      "\(newName), 원본 \(moved != nil), 변형 \(mv != nil)")
                // 다시 잇기: 파일을 치우고 오프라인 표시 → 다른 폴더에서 이름으로 찾기
                let lost = URL(fileURLWithPath: items[1].url.path)
                let hide = root.appendingPathComponent("elsewhere/deep")
                try? fm.createDirectory(at: hide, withIntermediateDirectories: true)
                try? fm.moveItem(at: lost, to: hide.appendingPathComponent(lost.lastPathComponent))
                _ = try? cat.db.run("UPDATE images SET offline = 1 WHERE path = ?", [lost.path])
                var found: URL?
                if let e = fm.enumerator(at: root.appendingPathComponent("elsewhere"), includingPropertiesForKeys: nil) {
                    for case let u as URL in e where u.lastPathComponent == lost.lastPathComponent { found = u }
                }
                if let found { try? cat.movePath(from: lost, to: found) }
                check("원본 다시 잇기", (try? cat.count(.offline)) == 0 && found != nil, "오프라인 \((try? cat.count(.offline)) ?? -1)")
                // XMP 쓰기·읽기 (다른 카탈로그로 읽어 값이 같은가)
                lib.show(.all)
                if let it = lib.items.first(where: { $0.id == items[0].id }) {
                    it.flag = 1; it.color = 3
                    let text = MainWindowController.xmp(for: it, catalog: cat)
                    let xurl = root.appendingPathComponent("t.xmp")
                    try? text.write(to: xurl, atomically: true, encoding: .utf8)
                    let cat2 = try? Catalog(url: root.appendingPathComponent("t2.duochromecatalog"))
                    if let cat2 {
                        let lib2 = Library(catalog: cat2)
                        _ = try? cat2.addFolder(other)
                        lib2.show(.all)
                        if let it2 = lib2.items.first {
                            _ = MainWindowController.readXMP(xurl, into: it2, library: lib2)
                            let kws = cat2.keywords(of: it2.id).map(\.1)
                            check("XMP 사이드카", it2.rating == 4 && it2.color == 3 && kws.contains("장소>서울>종로") && cat2.metadata(it2.id)["title"] == "시험 제목",
                                  "별점 \(it2.rating), 색 \(it2.color), 키워드 \(kws), 제목 \(cat2.metadata(it2.id)["title"] ?? "-")")
                        }
                    }
                }
            }
            // 룩 맞추기: 같은 통계면 그대로, 다른 기준이면 평균이 기준 쪽으로
            let warm = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
            let cool = CIImage(color: CIColor(red: 0.3, green: 0.45, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
            let sw = MainWindowController.labStats(warm), sc = MainWindowController.labStats(cool)
            let same = MainWindowController.lookTransfer(from: sw, to: sw)(SIMD3(0.4, 0.5, 0.6))
            let moved = MainWindowController.lookTransfer(from: sw, to: sc)
            let wv = SIMD3<Float>(Float(0.7), 0.5, 0.3)
            let m = moved(PSDAdjust.fromLab(PSDAdjust.toLab(wv)))
            check("룩 맞추기", abs(same.x - 0.4) < 0.01 && abs(same.z - 0.6) < 0.01 && m.z > m.x, String(format: "그대로 %.3f %.3f %.3f, 따뜻한 색 → %.2f %.2f %.2f", same.x, same.y, same.z, m.x, m.y, m.z))
            // 교정쇄 프로파일 (CMYK)
            let cmyk = ProofProfile.available().first { $0.lastPathComponent.lowercased().contains("cmyk") }
            if let cmyk {
                ProofProfile.current = cmyk
                let l = ProofProfile.luts(cmyk)
                ProofProfile.current = nil
                if let (proof, warn) = l {
                    let p = proof.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, w = warn.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    let n = 17
                    func idx(_ r: Int, _ g: Int, _ b: Int) -> Int { (b * n * n + g * n + r) * 4 }
                    let green = idx(0, 16, 0), gray = idx(8, 8, 8)
                    check("교정쇄 프로파일 (\(cmyk.deletingPathExtension().lastPathComponent))", w[green] == 1 && w[gray] == 0 && abs(p[gray] - 0.5) < 0.08,
                          String(format: "순초록 색역 밖, 회색 %.2f", p[gray]))
                } else { check("교정쇄 프로파일", false, "LUT를 못 만듦") }
            }
            // 웹용 인코딩
            let tex = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)).applyingFilter("CIRandomGenerator").cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
            if let cg = Render.context.createCGImage(CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)), from: CGRect(x: 0, y: 0, width: 256, height: 256)) {
                let lo = WebExportWindow.encode(cg, type: .jpeg, quality: 0.3)?.count ?? 0, hi = WebExportWindow.encode(cg, type: .jpeg, quality: 0.95)?.count ?? 0
                check("웹용 내보내기 인코딩", lo > 0 && hi > lo * 2, "품질 30: \(lo)B, 95: \(hi)B, 형식 \(WebExportWindow.formats.map(\.title))")
            }
            _ = tex
            // 스타일 브러시 변환
            let la = MainWindowController.localAdjust(fromStyle: ["exposure": 0.5, "contrast": 20, "temperature": 6000], current: DevelopSettings())
            check("스타일 브러시 변환", la.exposure == 0.5 && la.contrast == 20 && la.temperature == 20, "노출 \(la.exposure) 대비 \(la.contrast) 색온도 \(la.temperature)")
            try? fm.removeItem(at: root)
        }

        // 34~39. 합치기: 실제 CR3 한 장으로 만든 가짜 묶음 (노출 차이·어긋남·가림·흐림·겹친 조각)
        let rawSample = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUOCHROME_SAMPLE_RAW"] ?? "")
        if FileManager.default.fileExists(atPath: rawSample.path), let fr = try? Merge.load(rawSample, scale: 0.25) {
            let base = fr.image
            let e = base.extent
            func stats(_ a: CIImage, _ b: CIImage, rect r: CGRect? = nil) -> Float {
                let rr = (r ?? e).integral
                let k = min(1, 400 / max(rr.width, rr.height))
                func px(_ i: CIImage) -> [Float] {
                    let sm = i.cropped(to: rr).transformed(by: .init(translationX: -rr.minX, y: -rr.minY)).transformed(by: .init(scaleX: k, y: k))
                    let q = CGRect(x: 0, y: 0, width: Int(rr.width * k), height: Int(rr.height * k))
                    var p = [Float](repeating: 0, count: Int(q.width) * Int(q.height) * 4)
                    Render.context.render(sm, toBitmap: &p, rowBytes: Int(q.width) * 16, bounds: q, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    return p
                }
                let pa = px(a), pb = px(b)
                var sum: Float = 0, n: Float = 0
                for i in stride(from: 0, to: pa.count, by: 4) { for c in 0 ..< 3 { sum += abs(min(pa[i + c], 1) - min(pb[i + c], 1)) }; n += 3 }
                return sum / max(n, 1)
            }
            func clip(_ i: CIImage, _ gain: Double) -> CIImage {
                i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(gain)]).applyingFilter("CIColorClamp").cropped(to: e)
            }
            // 34. HDR: −2·0·+2 EV (각각 1에서 잘림) → 원래 선형 값
            let exps = [0.25, 1.0, 4.0]
            let scene = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 3]).cropped(to: e)   // 1을 넘는 곳이 많은 장면
            let brackets = exps.map { clip(scene, $0) }
            if let h = Merge.hdr(brackets, exposures: exps, reference: 1) {
                let dark = scene.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -4]).cropped(to: e)
                let hd = h.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -4]).cropped(to: e)
                let eh = stats(hd, dark), e0 = stats(brackets[1].applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -4]), dark)
                check("HDR 합치기", eh < 0.004 && eh < e0, String(format: "원래 값과 차이 %.4f (0 EV 한 장 %.4f)", eh, e0))
            }
            // 35. 맞추기: 37, −21 옮긴 그림
            let shifted = base.transformed(by: .init(translationX: 37, y: -21))
            if let hm = Merge.align(shifted, to: base, homographic: true) {
                let p = Merge.apply(hm, CGPoint(x: e.midX + 37, y: e.midY - 21))
                check("자동 정렬 (Vision)", abs(p.x - e.midX) < 2 && abs(p.y - e.midY) < 2, String(format: "옮긴 가운데 → (%.1f, %.1f), 기대 (%.1f, %.1f)", p.x, p.y, e.midX, e.midY))
            } else { check("자동 정렬 (Vision)", false, "맞추지 못함") }
            // 36. 중앙값: 장마다 다른 자리에 가림
            let occl = (0 ..< 3).map { i -> CIImage in
                let box = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: CGRect(x: e.minX + CGFloat(i) * e.width / 3 + 20, y: e.midY - 60, width: 120, height: 120))
                return box.composited(over: base).cropped(to: e)
            }
            if let md = Merge.median(occl), let mn = Merge.mean(occl) {
                let em = stats(md, base), ea = stats(mn, base), e1 = stats(occl[0], base)
                check("이미지 스택 (중앙값·평균)", em < 0.001 && ea > em && e1 > em, String(format: "중앙값 %.5f, 평균 %.5f, 한 장 %.5f", em, ea, e1))
            }
            // 37. 초점 스태킹: 왼쪽 흐린 장 + 오른쪽 흐린 장
            let blurred = base.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]).cropped(to: e)
            let left = CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height)
            let a = blurred.cropped(to: left).composited(over: base).cropped(to: e)
            let b = base.cropped(to: left).composited(over: blurred).cropped(to: e)
            if let fs = Merge.focusStack([a, b], scale: 0.25) {
                let ef = stats(fs, base), ea2 = stats(a, base)
                check("초점 스태킹", ef < ea2 * 0.45, String(format: "합친 결과 %.4f, 한 장 %.4f", ef, ea2))
            }
            // 38. 파노라마 (직선): 겹친 조각 셋 → 원래 사진
            let w3 = e.width * 0.45
            let pieces = (0 ..< 3).map { i -> Merge.Frame in
                let r = CGRect(x: e.minX + CGFloat(i) * e.width * 0.275, y: e.minY, width: w3, height: e.height).integral
                var f = fr; f.image = base.cropped(to: r).transformed(by: .init(translationX: -r.minX, y: -r.minY)); return f
            }
            do {
                let pano = try Merge.panorama(pieces, projection: .planar, scale: 0.25)
                let pw = pano.extent.width
                let shiftBack = pano.transformed(by: .init(translationX: -pano.extent.minX, y: -pano.extent.minY))
                let target = base.transformed(by: .init(translationX: -e.minX, y: -e.minY))
                let common = CGRect(x: 0, y: 0, width: min(pw, e.width), height: min(pano.extent.height, e.height))
                let ep = stats(shiftBack, target, rect: common)
                check("파노라마 (직선)", abs(pw - (e.width * 0.275 * 2 + w3)) < 16 && ep < 0.015, String(format: "폭 %.0f (기대 %.0f), 차이 %.4f", pw, e.width * 0.275 * 2 + w3, ep))
                let cyl = try Merge.panorama(pieces, projection: .cylindrical, scale: 0.25)
                let cropped = Merge.autoCrop(cyl)
                check("파노라마 (원통·잘라내기)", cyl.extent.width > w3 * 1.8 && cyl.extent.height < e.height * 1.2 && cropped.extent.height > e.height * 0.7 && cropped.extent.width > w3,
                      "원통 \(Int(cyl.extent.width))×\(Int(cyl.extent.height)) → 잘라 \(Int(cropped.extent.width))×\(Int(cropped.extent.height))")
            } catch { check("파노라마", false, "\(error)") }
            // 39. HDR DNG: 1을 넘는 값을 기준 노출로 적고 다시 열기
            let hdrURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-hdr.dng")
            let bright = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 5]).cropped(to: e)
            do {
                try Merge.writeDNG(bright, to: hdrURL, camera: fr.camera)
                let back = CIRAWFilter(imageURL: hdrURL)
                let be = back?.baselineExposure ?? 0
                check("HDR DNG 쓰기", back?.outputImage != nil && be > 0.5, String(format: "기준 노출 %+.2f EV", be))
            } catch { check("HDR DNG 쓰기", false, "\(error)") }
        }

        // 40. LCC: 가장자리가 어둡고 푸른 지도로 나누면 평평해진다
        do {
            let r = CGRect(x: 0, y: 0, width: 200, height: 100)
            let vig = CIFilter(name: "CIRadialGradient", parameters: [kCIInputCenterKey: CIVector(x: 100, y: 50), "inputRadius0": 20, "inputRadius1": 120,
                                                                      "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0.5, green: 0.55, blue: 0.7)])!.outputImage!.cropped(to: r)
            if let cg = Render.context.createCGImage(vig, from: r, format: .RGBAh, colorSpace: Render.workingSpace), let file = PSDImport.writeImage(cg, float: true) {
                let flat = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: r)
                let shot = flat.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: vig]).cropped(to: r)
                let fixed = LCC.apply(shot, file: file, mode: 3, scale: 1)
                var p = [Float](repeating: 0, count: 8)
                Render.context.render(fixed, toBitmap: &p, rowBytes: 32, bounds: CGRect(x: 1, y: 1, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
                var q = [Float](repeating: 0, count: 4)
                Render.context.render(shot, toBitmap: &q, rowBytes: 16, bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                var f0 = [Float](repeating: 0, count: 4)
                Render.context.render(flat, toBitmap: &f0, rowBytes: 16, bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                check("LCC 평면 보정", abs(p[0] - f0[0]) < 0.01 && abs(p[2] - f0[2]) < 0.01, String(format: "모서리 %.3f %.3f %.3f → %.3f %.3f %.3f", q[0], q[1], q[2], p[0], p[1], p[2]))
            }
        }

        // 41~47. 변형
        do {
            var im = LayerImage(file: "x", cx: 500, cy: 400, width: 300, rotation: 20)
            let asp = 0.5
            // 자유 변형 모서리 = 기본 자리의 모서리면 같은 자리
            im.quad = Warp.corners(im, aspect: asp).flatMap { [$0.x, $0.y] }
            let a1 = Warp.map(im, aspect: asp, 0.3, 0.7), b1 = Warp.basePoint(im, aspect: asp, 0.3, 0.7)
            im.quad = nil
            im.mesh = Warp.identityMesh(im, aspect: asp)
            let a2 = Warp.map(im, aspect: asp, 0.8, 0.2), b2 = Warp.basePoint(im, aspect: asp, 0.8, 0.2)
            im.mesh = nil
            im.pins = [100, 100, 150, 120, 900, 100, 950, 120]   // 두 핀을 같이 옮기면 평행 이동
            let a3 = Warp.map(im, aspect: asp, 0.5, 0.5), b3 = Warp.basePoint(im, aspect: asp, 0.5, 0.5)
            check("자유 변형·뒤틀기·퍼펫 (좌표)", hypot(a1.x - b1.x, a1.y - b1.y) < 0.01 && hypot(a2.x - b2.x, a2.y - b2.y) < 0.01
                  && abs(a3.x - b3.x - 50) < 0.5 && abs(a3.y - b3.y - 20) < 0.5,
                  String(format: "원근 %.3f, 격자 %.3f, 핀 이동 (%.1f, %.1f)", hypot(a1.x - b1.x, a1.y - b1.y), hypot(a2.x - b2.x, a2.y - b2.y), a3.x - b3.x, a3.y - b3.y))
            if let dir = ProcessInfo.processInfo.environment["DUOCHROME_PSD_DUMP"] {
                let chk = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 30, "inputColor0": CIColor(red: 0.9, green: 0.8, blue: 0.2), "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.5)])!
                    .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
                var w = LayerImage(file: "x", cx: 400, cy: 300, width: 600)
                var m = Warp.identityMesh(w, aspect: 400.0 / 600)
                m[5 * 2] += 80; m[5 * 2 + 1] += 60; m[10 * 2] -= 60
                w.mesh = m
                w.pins = [200, 200, 200, 200, 600, 400, 640, 460]
                let wr = Warp.render(chk, w, scale: 1, canvas: CGRect(x: 0, y: 0, width: 800, height: 600))
                print("디버그 warp 결과 영역", wr.extent)
                let big = wr.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)))
                for pt in [CGPoint(x: 20, y: 488), CGPoint(x: 400, y: 300), CGPoint(x: 111, y: 20)] {
                    var v = [Float](repeating: 0, count: 4)
                    Render.context.render(big, toBitmap: &v, rowBytes: 16, bounds: CGRect(origin: pt, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: nil)
                    print("디버그 점", pt, v)
                }
                if let cg = Render.context.createCGImage(big.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)), from: CGRect(x: 0, y: 0, width: 800, height: 600)) {
                    try? Render.context.writePNGRepresentation(of: CIImage(cgImage: cg), to: URL(fileURLWithPath: dir + "/warp-cg2.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                let out = wr.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)))
                try? Render.context.writePNGRepresentation(of: out.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)), to: URL(fileURLWithPath: dir + "/warp.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            // 원근 자르기 + 캔버스 여백: 좌표 되돌리기와 크기
            var g = DevelopSettings()
            g.perspective = [100, 50, 3900, 300, 3800, 2900, 200, 2600]
            g.crop = CropRect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            g.canvasPad = [0.1, 0.05, 0.1, 0.05]
            let nat = CGSize(width: 4000, height: 3000)
            var worst = 0.0
            for i in 0 ..< 50 {
                let p = CGPoint(x: Double(300 + i * 61), y: Double(400 + (i * 37) % 2000))
                let q = Geometry.fromDisplay(Geometry.toDisplay(p, g, native: nat, fullFrame: false), g, native: nat, fullFrame: false)
                worst = max(worst, hypot(q.x - p.x, q.y - p.y))
            }
            let fs = Geometry.frameSize(g, native: nat), cs = Geometry.croppedSize(g, native: nat)
            // 그림과 좌표가 같은 곳을 가리키나: 원본의 한 점을 그려서 찾는다
            let dot = CGPoint(x: 1900, y: 1500)
            let dimg = CIImage(color: .white).cropped(to: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))
                .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: nat)))
            let shaped = Geometry.crop(g, Geometry.transform(g, dimg, scale: 1))
            let pred = Geometry.toDisplay(dot, g, native: nat, fullFrame: false)
            let win = CGRect(x: (pred.x - 30).rounded(.down), y: (pred.y - 30).rounded(.down), width: 60, height: 60)
            var px = [Float](repeating: 0, count: 60 * 60 * 4)
            Render.context.render(shaped, toBitmap: &px, rowBytes: 60 * 16, bounds: win, format: .RGBAf, colorSpace: nil)
            var sx = 0.0, sy = 0.0, sw = 0.0
            for y in 0 ..< 60 { for x in 0 ..< 60 { let v = Double(px[(y * 60 + x) * 4]); sx += v * Double(x); sy += v * Double(59 - y); sw += v } }
            let found = CGPoint(x: win.minX + sx / max(sw, 1e-6) + 0.5, y: win.minY + sy / max(sw, 1e-6) + 0.5)
            check("원근 자르기·캔버스 크기", worst < 0.01 && abs(shaped.extent.width - cs.width) < 2 && hypot(found.x - pred.x, found.y - pred.y) < 2,
                  String(format: "되돌리기 %.4f, 틀 %.0f×%.0f, 결과 %.0f×%.0f (계산 %.0f×%.0f), 점 어긋남 %.2f", worst, fs.width, fs.height,
                         shaped.extent.width, shaped.extent.height, cs.width, cs.height, hypot(found.x - pred.x, found.y - pred.y)))
            // 유동화: 부풀리기는 가운데 근처만 바꾼다
            let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 20, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!
                .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
            let lq = Warp.liquify(checker, strokes: [LiquifyStroke(tool: 1, points: [400, 300], radius: 120, strength: 1)], native: CGSize(width: 800, height: 600), scale: 1)
            func diff(_ r: CGRect) -> Float {
                var a = [Float](repeating: 0, count: Int(r.width * r.height) * 4), b = a
                Render.context.render(checker, toBitmap: &a, rowBytes: Int(r.width) * 16, bounds: r, format: .RGBAf, colorSpace: nil)
                Render.context.render(lq, toBitmap: &b, rowBytes: Int(r.width) * 16, bounds: r, format: .RGBAf, colorSpace: nil)
                return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(a.count)
            }
            let dNear = diff(CGRect(x: 350, y: 250, width: 100, height: 100)), dFar = diff(CGRect(x: 20, y: 20, width: 100, height: 100))
            check("픽셀 유동화", dNear > 0.05 && dFar < 0.001, String(format: "가운데 변화 %.3f, 먼 곳 %.5f", dNear, dFar))
            // 내용 인식 비율: 검은 바탕의 흰 띠 둘은 남고 빈 곳이 줄어든다
            let bars = CIImage(color: .white).cropped(to: CGRect(x: 150, y: 0, width: 40, height: 400))
                .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 600, y: 0, width: 40, height: 400)))
                .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 400)))
            if let out = SeamCarver.scale(bars, widthFactor: 0.6, heightFactor: 1) {
                let w = Int(out.extent.width)
                var row = [Float](repeating: 0, count: w * 4)
                Render.context.render(out, toBitmap: &row, rowBytes: w * 16, bounds: CGRect(x: 0, y: 200, width: w, height: 1), format: .RGBAf, colorSpace: nil)
                let white = stride(from: 0, to: row.count, by: 4).filter { row[$0] > 0.5 }.count
                check("내용 인식 비율", abs(w - 480) <= 2 && white >= 70 && white <= 90, "폭 \(w) (480), 흰 띠 \(white)px (80 기대 — 빈 곳만 줄어듦)")
            }
            // 적응형 광각: k=40으로 곧은 선을 k=0 자리로 굽혀 놓고 찾기
            let nat2 = CGSize(width: 6000, height: 4000)
            let straight = (0 ..< 20).map { CGPoint(x: 300 + Double($0) * 270, y: 3500) }
            let bent = straight.map { MainWindowController.undistort($0, from: 40, to: 0, native: nat2) }
            var sd = DevelopSettings(); sd.lensDistortion = 0
            let k = MainWindowController.solveDistortion([bent], sd, native: nat2)
            check("적응형 광각", abs(k - 40) < 3, String(format: "찾은 왜곡 %.1f (40 기대)", k))
            // 리샘플링 네 방식
            let sizes = (0 ..< 4).map { Exporter.resample(checker, 0.5, method: $0).extent.integral.width }
            check("이미지 크기·리샘플링", sizes.allSatisfy { abs($0 - 400) <= 4 }, "\(sizes) (바이큐빅은 가장자리를 몇 px 더 그린다)")
        }

        if let dir = ProcessInfo.processInfo.environment["DUOCHROME_GALLERY_DUMP"], let sample = ProcessInfo.processInfo.environment["DUOCHROME_SAMPLE_RAW"], let fr = try? Merge.load(URL(fileURLWithPath: sample), scale: 0.125) {
            let base = fr.image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.3])
            let b = base.transformed(by: .init(translationX: -base.extent.minX, y: -base.extent.minY))
            let cw = b.extent.width, ch = b.extent.height
            let kinds = Effects.galleryFilters.map(\.kind)
            let cols = 7
            let rows = (kinds.count + cols - 1) / cols
            var sheet = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: cw * CGFloat(cols), height: ch * CGFloat(rows)))
            for (n, k) in kinds.enumerated() {
                let o = Effects.apply([LayerEffect(kind: k)], b, scale: 0.125).cropped(to: b.extent)
                sheet = o.transformed(by: .init(translationX: CGFloat(n % cols) * cw, y: CGFloat(rows - 1 - n / cols) * ch)).composited(over: sheet)
            }
            try? Render.context.writeJPEGRepresentation(of: sheet.cropped(to: sheet.extent), to: URL(fileURLWithPath: dir + "/gallery.jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            for k in ["g_chalkCharcoal", "g_conteCrayon", "g_stamp", "g_photocopy", "g_cutout", "g_mosaicTiles"] {
                let o = Effects.apply([LayerEffect(kind: k)], b, scale: 0.125).cropped(to: b.extent)
                if let cg = Render.context.createCGImage(o, from: b.extent) {
                    try? Render.context.writeJPEGRepresentation(of: CIImage(cgImage: cg), to: URL(fileURLWithPath: dir + "/g-\(k).jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
            }
        }
        if ProcessInfo.processInfo.environment["DUOCHROME_WB_CALIB"] != nil, let sample = ProcessInfo.processInfo.environment["DUOCHROME_SAMPLE_RAW"], let doc = try? RawDocument(url: URL(fileURLWithPath: sample)) {
            func avg(_ t: Float, _ ti: Float) -> SIMD3<Double> {
                var s = doc.asShot; s.filmCurve = 0; s.look = 0; s.temperature = t; s.tint = ti
                doc.settings = s; doc.usePreviewCache = false
                let img = doc.image(scale: 0.125)
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)]), toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
                return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
            }
            let T0 = doc.asShot.temperature, t0 = doc.asShot.tint
            let a = avg(T0, t0)
            for (dT, dt) in [(Float(0), Float(0)), (-500, 0), (500, 0), (1000, 0), (0, 10), (0, -10)] {
                let b = avg(T0 + dT, t0 + dt)
                print("보정", T0 + dT, t0 + dt, "mired", 1e6 / Double(T0 + dT) - 1e6 / Double(T0), "ln(R/B)", log(b.x / b.z) - log(a.x / a.z), "ln(G²/RB)", log(b.y * b.y / (b.x * b.z)) - log(a.y * a.y / (a.x * a.z)))
            }
        }
        // 48. 렌즈 흐림 깊이 맵: 왼쪽 가까움(초점)·오른쪽 멂 → 오른쪽만 흐려진다
        do {
            let r = CGRect(x: 0, y: 0, width: 400, height: 200)
            let depth = CIImage(color: .white).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200)).composited(over: CIImage(color: .black).cropped(to: r))
            if let png = Render.context.pngRepresentation(of: depth, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
               let file = try? LayerImageStore.importData(png, ext: "png") {
                let chk = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 6, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: r)
                var fx = LayerEffect(kind: "lensBlur"); fx.text = "depth:" + file
                fx.params["source"] = 1; fx.params["focus"] = 0; fx.params["depth"] = 0.2; fx.params["radius"] = 10
                let out = Effects.apply([fx], chk, scale: 1)
                func contrast(_ rr: CGRect) -> Float {
                    var p = [Float](repeating: 0, count: Int(rr.width * rr.height) * 4)
                    Render.context.render(out, toBitmap: &p, rowBytes: Int(rr.width) * 16, bounds: rr, format: .RGBAf, colorSpace: nil)
                    let v = stride(from: 0, to: p.count, by: 4).map { p[$0] }
                    return (v.max() ?? 0) - (v.min() ?? 0)
                }
                let near = contrast(CGRect(x: 60, y: 80, width: 40, height: 40)), far = contrast(CGRect(x: 300, y: 80, width: 40, height: 40))
                check("렌즈 흐림 깊이 맵", near > 0.8 && far < 0.3, String(format: "가까운 쪽 대비 %.2f, 먼 쪽 %.2f", near, far))
            }
        }

        // 49~51. 칠하기: 브러시 엔진
        do {
            let nat = CGSize(width: 400, height: 300)
            func render(_ st: [PaintStroke]) -> [Float] {
                let img = PaintRender.image(st, native: nat, scale: 1)
                var p = [Float](repeating: 0, count: 400 * 300 * 4)
                Render.context.render(img, toBitmap: &p, rowBytes: 400 * 16, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return p
            }
            func alpha(_ p: [Float], _ x: Int, _ y: Int) -> Float { p[((299 - y) * 400 + x) * 4 + 3] }
            var b = PaintBrush(); b.size = 30; b.color = [1, 0, 0]
            let line = [50.0, 150, 1, 350, 150, 1]
            let a = render([PaintStroke(brush: b, points: line, seed: 7)])
            var soft = b; soft.hardness = 0.1
            let sa = render([PaintStroke(brush: soft, points: line, seed: 7)])
            // 연필: 반투명 가장자리가 없다
            var pen = b; pen.mode = 2
            let pa = render([PaintStroke(brush: pen, points: line, seed: 7)])
            let partial = stride(from: 3, to: pa.count, by: 4).filter { pa[$0] > 0.05 && pa[$0] < 0.95 }.count
            // 지우개: 가운데를 지운다
            var er = b; er.mode = 1; er.size = 60
            let ea = render([PaintStroke(brush: b, points: line, seed: 7), PaintStroke(brush: er, points: [200, 150, 1], seed: 3)])
            check("기본 브러시·연필·지우개", alpha(a, 200, 150) > 0.95 && alpha(a, 200, 180) < 0.01 && alpha(sa, 200, 162) < alpha(a, 200, 162)
                  && partial < 40 && alpha(ea, 200, 150) < 0.05 && alpha(ea, 100, 150) > 0.9,
                  String(format: "가운데 %.2f, 부드러운 가장자리 %.2f < %.2f, 연필 반투명 %d, 지운 곳 %.2f", alpha(a, 200, 150), alpha(sa, 200, 162), alpha(a, 200, 162), partial, alpha(ea, 200, 150)))
            // 브러시 엔진: 흔들림·산포는 같은 씨앗이면 같고, 다른 씨앗이면 다르다
            var j = b; j.sizeJitter = 0.8; j.scatter = 1; j.spacing = 0.5; j.hueJitter = 0.5
            let j1 = render([PaintStroke(brush: j, points: line, seed: 11)]), j2 = render([PaintStroke(brush: j, points: line, seed: 11)]), j3 = render([PaintStroke(brush: j, points: line, seed: 12)])
            let off = stride(from: 3, to: j1.count, by: 4).filter { j1[$0] > 0.5 }.count
            check("브러시 엔진 (흔들림·산포·색 변화)", j1 == j2 && j1 != j3 && off > 1000, "칠한 픽셀 \(off)")
            // 혼합 브러시: 묻힌 색이 붓질 따라 바뀐다
            var m = b; m.mode = 3
            let mixed = PaintStroke(brush: m, points: line, seed: 1, mixed: (0 ..< 200).flatMap { k in [Float(1) - Float(k) / 200, 0, Float(k) / 200] })
            let ma = render([mixed])
            let left = ma[((150) * 400 + 60) * 4], right = ma[((150) * 400 + 340) * 4]
            check("혼합 브러시", left > right + 0.2, String(format: "왼쪽 빨강 %.2f, 오른쪽 %.2f", left, right))
        }

        // 52. 그림: 모양 레이어(채우기·획·점선·별), 벡터 마스크, 글자(가로·세로·단락·뒤틀기·패스 위) 합성
        do {
            let N = CGSize(width: 1200, height: 800)
            let base = CIImage(color: CIColor(red: 0.18, green: 0.2, blue: 0.24)).cropped(to: CGRect(origin: .zero, size: N))
            var layers: [AdjustLayer] = []
            func shapeLayer(_ p: VectorPath, fill: [Float]?, stroke: [Float]?, width: Double = 8, dash: [Double] = []) -> AdjustLayer {
                var l = AdjustLayer(name: "모양"); l.kind = "shape"
                l.vector = VectorShape(path: p, fill: fill, stroke: stroke, strokeWidth: width, dash: dash)
                return l
            }
            layers.append(shapeLayer(.preset(.roundRect, in: CGRect(x: 40, y: 480, width: 300, height: 260), radius: 50), fill: [0.95, 0.35, 0.3], stroke: [1, 1, 1], width: 10))
            layers.append(shapeLayer(.preset(.star, in: CGRect(x: 380, y: 480, width: 260, height: 260), sides: 5), fill: [1, 0.85, 0.2], stroke: nil))
            layers.append(shapeLayer(.preset(.ellipse, in: CGRect(x: 680, y: 480, width: 240, height: 260)), fill: nil, stroke: [0.4, 0.8, 1], width: 12, dash: [30, 18]))
            layers.append(shapeLayer(.preset(.arrow, in: CGRect(x: 960, y: 560, width: 200, height: 120)), fill: [0.5, 1, 0.5], stroke: nil))
            // 벡터 마스크를 건 큰 사각형
            var masked = shapeLayer(.preset(.rect, in: CGRect(x: 40, y: 40, width: 360, height: 400)), fill: [0.3, 0.5, 1], stroke: nil)
            masked.mask.vector = .preset(.polygon, in: CGRect(x: 60, y: 60, width: 320, height: 360), sides: 6)
            layers.append(masked)
            func text(_ s: String, _ f: (inout LayerText) -> Void) -> AdjustLayer {
                var l = AdjustLayer(name: s); l.kind = "text"
                var t = LayerText(string: s, font: "AppleSDGothicNeo-Bold", size: 56, color: [1, 1, 1], x: 440, y: 380)
                f(&t); l.text = t
                return l
            }
            layers.append(text("부채꼴 뒤틀기") { $0.warp = TextWarp.arc.rawValue; $0.warpBend = 50 })
            layers.append(text("세로쓰기") { $0.vertical = true; $0.x = 1150; $0.y = 460; $0.size = 48 })
            layers.append(text("단락 글자는 상자 너비에서 줄을 바꿉니다. 긴 문장도 상자 안에 들어갑니다.") {
                $0.size = 30; $0.x = 440; $0.y = 300; $0.boxWidth = 330; $0.boxHeight = 200; $0.color = [0.9, 0.9, 0.7]
            })
            var arcPath = VectorPath.preset(.ellipse, in: CGRect(x: 820, y: 60, width: 300, height: 300))
            arcPath.closed = true
            layers.append(text("패스를 따라 도는 글자 · 패스 위 글자 · ") { $0.size = 30; $0.onPath = arcPath; $0.color = [1, 0.7, 0.9] })
            let out = Layers.apply(layers, to: base, guide: base, scale: 1, guideScale: 1, native: N, shape: { m, _ in m })
            var px = [Float](repeating: 0, count: 4)
            Render.context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 190, y: 610, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let redOK = px[0] > 0.85 && px[1] < 0.5
            Render.context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 50, y: 50, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let maskedOut = px[2] < 0.4   // 사각형 모서리는 육각형 벡터 마스크 밖이라 바탕색
            Render.context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 220, y: 240, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let maskedIn = px[2] > 0.8
            if let path = ProcessInfo.processInfo.environment["DUOCHROME_J_PNG"] {
                try? Render.context.writePNGRepresentation(of: out, to: URL(fileURLWithPath: path), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            check("J 모양·벡터 마스크·글자 합성", redOK && maskedOut && maskedIn, "빨간 둥근 사각형 \(redOK), 벡터 마스크 밖 \(maskedOut) 안 \(maskedIn)")
        }

        // 53. 색 모드: 회색조·이중톤·CMYK 왕복·문서 색 공간 변환·8비트·채널 보기·Lab·CMYK·회색 쓰기
        do {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
                CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: srgb)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            func px(_ i: CIImage) -> [Float] {
                var p = [Float](repeating: 0, count: 4)
                Render.context.render(i, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
                return p
            }
            var s = DevelopSettings()
            s.docMode = DocMode.gray.rawValue
            let g = px(ColorModes.apply(s, solid(0.8, 0.3, 0.1)))
            let grayOK = abs(g[0] - g[1]) < 0.01 && abs(g[1] - g[2]) < 0.01
            s.docMode = DocMode.duotone.rawValue
            let d = px(ColorModes.apply(s, solid(0.5, 0.5, 0.5)))
            let duoOK = d[0] > d[2] + 0.05   // 세피아 잉크: 빨강이 파랑보다 많다
            s.docMode = DocMode.cmyk.rawValue
            let c = px(ColorModes.apply(s, solid(0, 1, 0)))
            let cmykOK = c[1] < 0.99 && (c[0] > 0.02 || c[2] > 0.02)   // 형광 초록은 CMYK 색역 밖
            // 문서 색 공간 sRGB: Rec.2020의 아주 짙은 초록이 sRGB 안으로 들어온다
            s.docMode = nil; s.docSpace = ExportRecipe.Space.sRGB.rawValue
            let wide = CIImage(color: CIColor(red: 0, green: 1, blue: 0, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let before = px(wide), after = px(ColorModes.apply(s, wide))
            let spaceOK = before[0] < -0.01 && after[0] > -0.005 && after.prefix(3).allSatisfy { $0 >= -0.005 && $0 <= 1.005 }
            // 8비트: 256단계
            s.docSpace = nil; s.docDepth = 8
            let q = px(ColorModes.apply(s, solid(0.1234, 0.5, 0.5)))
            let depthOK = abs(q[0] * 255 - (q[0] * 255).rounded()) < 0.02
            // 채널 보기: 빨간 그림의 빨강 채널은 흰색, 파랑 채널은 검정. CMYK 검정 채널은 검은 그림에서 검정
            let red = solid(1, 0, 0)
            let rch = px(ColorModes.channelView(red, mode: .rgb, channel: 1)), bch = px(ColorModes.channelView(red, mode: .rgb, channel: 3))
            let kch = px(ColorModes.channelView(solid(0, 0, 0), mode: .cmyk, channel: 4))
            let lch = px(ColorModes.channelView(solid(1, 1, 1), mode: .lab, channel: 1))
            let chOK = rch[0] > 0.98 && bch[0] < 0.02 && kch[0] < 0.02 && lch[0] > 0.97
            // 쓰기: Lab TIFF·CMYK JPEG·회색 PNG를 파일로 쓰고 다시 읽어 색 모델 확인
            let cg = Render.context.createCGImage(solid(0.7, 0.4, 0.2), from: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8, colorSpace: srgb)!
            func roundTrip(_ img: CGImage, _ type: UTType) -> CGColorSpaceModel? {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-mode-\(UUID().uuidString)")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(dest, img, nil)
                guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                try? FileManager.default.removeItem(at: url)
                return back.colorSpace?.model
            }
            let labM = roundTrip(ColorModes.convertForExport(cg, mode: .lab, format: .tiff8), .tiff)
            let cmykM = roundTrip(ColorModes.convertForExport(cg, mode: .cmyk, format: .jpeg), .jpeg)
            let grayM = roundTrip(ColorModes.convertForExport(cg, mode: .gray, format: .png), .png)
            let (L, a, b) = ColorModes.toLab(1, 1, 1)
            let writeOK = labM == .lab && cmykM == .cmyk && grayM == .monochrome && abs(L - 100) < 0.5 && abs(a) < 0.5 && abs(b) < 0.5
            check("L 색 모드 (회색조·이중톤·CMYK·색 공간 변환·8비트·채널·Lab/CMYK/회색 쓰기)",
                  grayOK && duoOK && cmykOK && spaceOK && depthOK && chOK && writeOK,
                  "회색 \(grayOK), 이중톤 \(duoOK), CMYK \(cmykOK) \(c.prefix(3).map { String(format: "%.2f", $0) }), 색 공간 \(spaceOK) \(String(format: "%.2f→%.2f", before[0], after[0])), 8비트 \(depthOK), 채널 \(chOK), 쓰기 Lab \(String(describing: labM)) CMYK \(String(describing: cmykM)) 회색 \(String(describing: grayM))")
        }

        print(failures == 0 ? "모두 통과" : "\(failures)개 실패")
        exit(failures == 0 ? 0 : 1)
    }

    /// 외부 카탈로그 가져오기 시험 (DUOCHROME_CATALOG_TEST=카탈로그 경로). 임시 카탈로그·임시 조정값 폴더에만 쓴다.
    static func catalogImport(_ path: String) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let catURL = tmp.appendingPathComponent("duochrome-importtest.duochromecatalog")
        try? FileManager.default.removeItem(at: catURL)
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent("duochrome-test-adjustments"))
        do {
            let catalog = try Catalog(url: catURL)
            let library = Library(catalog: catalog)
            let t0 = Date()
            let report = try CatalogImport.run(package: URL(fileURLWithPath: path), into: catalog, library: library) { print("…", $0) }
            print(report.summary)
            print(String(format: "걸린 시간 %.1f초", Date().timeIntervalSince(t0)))
            // 확인용: 앨범 몇 개와 그 사진 수, 미세 회전이 있던 사진의 가져온 값
            for a in try catalog.albums().prefix(12) {
                print("  앨범", a.kind == 0 ? "[그룹]" : "", a.name, "·", try catalog.count(.album(a.id)), "장")
            }
            // 크롭·화이트 밸런스 확인: 원본이 있는 사진(DUOCHROME_CATALOG_TEST_PHOTO=파일 이름)을 우리 방식으로 그려 가져온 썸네일과 비교
            let probe = ProcessInfo.processInfo.environment["DUOCHROME_CATALOG_TEST_PHOTO"] ?? ""
            if !probe.isEmpty, let row = try? catalog.items(.all).first(where: { $0.name == probe && !$0.offline }), let d = try? RawDocument(url: row.url),
               let s = library.loadSettings(for: row.url, over: d.asShot) {
                d.settings = s; d.applyImportedWB()
                let img = d.image(scale: 0.125)
                var tp: String?
                try? catalog.db.query("SELECT import_thumb FROM images WHERE id = ?", [row.id]) { tp = $0.text(0) }
                func gray(_ i: CIImage) -> [Float] {
                    let k = 200 / i.extent.width
                    let sm = i.transformed(by: .init(translationX: -i.extent.minX, y: -i.extent.minY)).transformed(by: .init(scaleX: k, y: k))
                    let r = CGRect(x: 0, y: 0, width: 200, height: Int(sm.extent.height))
                    var p = [Float](repeating: 0, count: Int(r.width * r.height) * 4)
                    Render.context.render(sm, toBitmap: &p, rowBytes: 200 * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    return stride(from: 0, to: p.count, by: 4).map { p[$0] * 0.3 + p[$0 + 1] * 0.59 + p[$0 + 2] * 0.11 }
                }
                if let tp, let th = CIImage(contentsOf: URL(fileURLWithPath: tp)) {
                    let a = gray(img), b = gray(th)
                    let n = min(a.count, b.count)
                    let ma = a.prefix(n).reduce(0, +) / Float(n), mb = b.prefix(n).reduce(0, +) / Float(n)
                    var num: Float = 0, da: Float = 0, db: Float = 0
                    for i in 0 ..< n { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
                    print(String(format: "  크롭 확인 %@: 우리 %.0f×%.0f (비 %.3f), 가져온 썸네일 %.0f×%.0f (비 %.3f), 밝기 상관 %.3f, 색온도 %.0fK (기록 %.0fK) 틴트 %.1f",
                                 probe, img.extent.width, img.extent.height, img.extent.width / img.extent.height, th.extent.width, th.extent.height,
                                 th.extent.width / th.extent.height, num / sqrt(da * db + 1e-9), d.settings.temperature, d.asShot.temperature, d.settings.tint))
                    if let dir = ProcessInfo.processInfo.environment["DUOCHROME_PSD_DUMP"] {
                        try? Render.context.writeJPEGRepresentation(of: img, to: URL(fileURLWithPath: dir + "/import-ours.jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        try? FileManager.default.copyItem(atPath: tp, toPath: dir + "/import-thumb.jpg")
                    }
                }
            }
            for name in [probe] where !probe.isEmpty {
                var path = ""
                try catalog.db.query("SELECT path FROM images WHERE filename = ? LIMIT 1", [name]) { path = $0.text(0) ?? "" }
                let url = URL(fileURLWithPath: path)
                let raw = library.rawSettings(for: url).flatMap { String(data: $0, encoding: .utf8) } ?? "(조정값 없음)"
                print("  \(name): \(raw.prefix(160))")
            }
            exit(0)
        } catch {
            print("실패:", error)
            exit(1)
        }
    }
}
