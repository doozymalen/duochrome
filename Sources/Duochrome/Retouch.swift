import CoreImage

/// One retouch spot. Coordinates and radius are in decoded source pixels, so it sticks to the photo content through crop/rotation changes.
struct RetouchSpot: Equatable, Hashable, Codable {
    enum Kind: String, Codable { case heal, clone }
    var kind: Kind = .heal
    var targetX: Double, targetY: Double
    var sourceX: Double, sourceY: Double
    var radius: Double
    /// Edge feather 0–1.
    var feather: Double = 0.5
    var opacity: Double = 1
    /// For a stroke, the points passed (x0, y0, x1, y1, …). The first point is target; the source is the stroke offset by the same distance from target.
    var path: [Double]? = nil
    /// Patch: path is a closed lasso (the area to fix). The source is the lasso moved by offset.
    var patch: Bool? = nil

    var isStroke: Bool { (path?.count ?? 0) >= 4 }
    var isPatch: Bool { patch == true && (path?.count ?? 0) >= 6 }
    var points: [CGPoint] {
        guard let p = path else { return [target] }
        return stride(from: 0, to: p.count - 1, by: 2).map { CGPoint(x: p[$0], y: p[$0 + 1]) }
    }
    var offset: CGPoint { CGPoint(x: sourceX - targetX, y: sourceY - targetY) }

    /// Moves the whole stroke (source too).
    mutating func move(by d: CGPoint) {
        targetX += d.x; targetY += d.y; sourceX += d.x; sourceY += d.y
        if var p = path {
            for i in stride(from: 0, to: p.count - 1, by: 2) { p[i] += d.x; p[i + 1] += d.y }
            path = p
        }
    }

    var target: CGPoint {
        get { CGPoint(x: targetX, y: targetY) }
        set { targetX = newValue.x; targetY = newValue.y }
    }
    var source: CGPoint {
        get { CGPoint(x: sourceX, y: sourceY) }
        set { sourceX = newValue.x; sourceY = newValue.y }
    }
}

/// Healing brush and clone stamp. Applied right after decoding, before geometry.
///
/// Heal: takes detail (high frequencies) from the source position, and brightness/color (low frequencies) from a **ring outside** the target.
/// Why only the ring: inside the target is the dust or blemish being removed, and its color would come back.
/// Low frequencies come from a ring-weighted blur divided by the blurred weights (normalized convolution).
enum Retouch {
    static func apply(_ spots: [RetouchSpot], to image: CIImage, scale: CGFloat) -> CIImage {
        var img = image
        for spot in spots { img = applySpot(spot, to: img, scale: scale) }
        return img
    }

    private static func applySpot(_ s: RetouchSpot, to img: CIImage, scale: CGFloat) -> CIImage {
        if s.isStroke { return applyStroke(s, to: img, scale: scale) }
        let r = max(CGFloat(s.radius) * scale, 1)
        let t = CGPoint(x: s.targetX * scale, y: s.targetY * scale)
        let src = CGPoint(x: s.sourceX * scale, y: s.sourceY * scale)
        // Compute only around the spot, with enough margin to cover the ring and blur.
        let region = CGRect(x: t.x - r * 3, y: t.y - r * 3, width: r * 6, height: r * 6).integral
            .intersection(img.extent)
        guard !region.isEmpty else { return img }

        // Offsets are whole pixels. Fractional offsets blur texture through interpolation.
        let shifted = img.clampedToExtent()
            .transformed(by: .init(translationX: (t.x - src.x).rounded(), y: (t.y - src.y).rounded()))
            .cropped(to: region)
        let local = img.clampedToExtent().cropped(to: region)
        let inner = r * CGFloat(1 - s.feather * 0.6)
        let mask = radial(t, inner, r, region)

        let result: CIImage
        switch s.kind {
        case .clone:
            result = GPU.run("clone_apply", [local, shifted, mask], params: [Float(s.opacity)], extent: region)
        case .heal:
            // Ring around the target (radius r – 1.6r). The source ring has the same shape.
            // (outside radius 1.05r) × (inside 1.6–2.0r)
            let ring = radial(t, r * 0.95, r * 1.05, region)
                .applyingFilter("CIColorInvert")
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: radial(t, r * 1.6, r * 2.0, region)])
                .cropped(to: region)
            let sigma = r * 0.6
            let den = ring.blurred(sigma)
            let numT = multiply(local, ring).blurred(sigma)
            let numS = multiply(shifted, ring).blurred(sigma)
            result = GPU.run("heal_apply", [local, shifted, numT, numS, den, mask],
                             params: [Float(s.opacity)], extent: region)
        }
        return result.composited(over: img).cropped(to: img.extent)
    }

    // MARK: - Strokes (removing wires and cracks)

    /// Heals/clones along a stroke. The mask is a thick blurred line; low frequencies come from bands on both sides of the stroke.
    private static func applyStroke(_ s: RetouchSpot, to img: CIImage, scale: CGFloat) -> CIImage {
        let r = max(CGFloat(s.radius) * scale, 1)
        let pts = s.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        let d = CGPoint(x: (-s.offset.x * scale).rounded(), y: (-s.offset.y * scale).rounded())
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts { box = box.union(CGRect(origin: p, size: .zero)) }
        let region = box.insetBy(dx: -r * 3, dy: -r * 3).integral.intersection(img.extent)
        guard !region.isEmpty else { return img }

        let shifted = img.clampedToExtent().transformed(by: .init(translationX: d.x, y: d.y)).cropped(to: region)
        let local = img.clampedToExtent().cropped(to: region)
        let feather = r * CGFloat(s.feather) * 0.5
        let masks = strokeMasks(pts, r: r, region: region, closed: s.isPatch)
        let mask = masks.core.blurred(max(feather, 0.5)).cropped(to: region)

        let result: CIImage
        switch s.kind {
        case .clone:
            result = GPU.run("clone_apply", [local, shifted, mask], params: [Float(s.opacity)], extent: region)
        case .heal:
            let sigma = r * 0.6
            let den = masks.ring.blurred(sigma)
            let numT = multiply(local, masks.ring).blurred(sigma)
            let numS = multiply(shifted, masks.ring).blurred(sigma)
            result = GPU.run("heal_apply", [local, shifted, numT, numS, den, mask],
                             params: [Float(s.opacity)], extent: region)
        }
        return result.composited(over: img).cropped(to: img.extent)
    }

    /// Two stroke masks: center (radius r) and side bands (1.15r – 1.9r). Drawn on the CPU (cached, redrawn only when the stroke changes).
    private static var maskCache: [String: (CIImage, CIImage)] = [:]
    private static let maskLock = NSLock()

    /// With `closed`, a patch lasso: the center is the filled polygon, the band is 1.15r – 1.9r outside it.
    private static func strokeMasks(_ pts: [CGPoint], r: CGFloat, region: CGRect, closed: Bool = false) -> (core: CIImage, ring: CIImage) {
        let key = "\(pts.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: ";"))|\(r)|\(region)|\(closed)"
        maskLock.lock(); defer { maskLock.unlock() }
        if let hit = maskCache[key] { return hit }
        func draw(_ widths: [(CGFloat, CGFloat)]) -> CIImage {
            let w = Int(region.width), h = Int(region.height)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for (width, gray) in widths {
                ctx.setStrokeColor(gray: gray, alpha: 1)
                ctx.setLineWidth(width)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: pts[0].x - region.minX, y: pts[0].y - region.minY))
                for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x - region.minX, y: p.y - region.minY)) }
                if pts.count == 1 { ctx.addLine(to: CGPoint(x: pts[0].x - region.minX + 0.01, y: pts[0].y - region.minY)) }
                if closed {
                    ctx.closePath()
                    let path = ctx.path
                    ctx.setFillColor(gray: gray, alpha: 1)
                    ctx.fillPath()
                    if width > 0, let path { ctx.addPath(path); ctx.strokePath() }
                } else {
                    ctx.strokePath()
                }
            }
            return CIImage(cgImage: ctx.makeImage()!).transformed(by: .init(translationX: region.minX, y: region.minY))
        }
        let result = closed ? (draw([(0, 1)]), draw([(r * 3.8, 1), (r * 2.3, 0)]))
                            : (draw([(r * 2, 1)]), draw([(r * 3.8, 1), (r * 2.3, 0)]))
        if maskCache.count > 64 { maskCache.removeAll() }
        maskCache[key] = result
        return result
    }

    /// Stroke source: among positions offset sideways along the stroke, the one whose side bands match best with no other line at the moved stroke.
    /// Wires usually run straight, so perpendicular candidates work well.
    static func pickStrokeOffset(_ path: [CGPoint], radius: Double, in small: CIImage, scale: CGFloat) -> CGPoint {
        let r = max(radius * Double(scale), 1.2)
        let pts = path.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        // Sample points at r intervals along the stroke with their normals.
        var samples: [(CGPoint, CGPoint)] = []
        for i in 0..<max(pts.count - 1, 1) {
            let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
            let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
            let steps = max(Int(len / r), 1)
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps)
                samples.append((CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), n))
            }
        }
        if samples.count > 200 { samples = stride(from: 0, to: samples.count, by: samples.count / 200 + 1).map { samples[$0] } }
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts { box = box.union(CGRect(origin: p, size: .zero)) }
        let region = box.insetBy(dx: -r * 7, dy: -r * 7).integral.intersection(small.extent)
        let w = Int(region.width), h = Int(region.height)
        let fallback = CGPoint(x: 0, y: radius * 3)
        guard w > 4, h > 4, !samples.isEmpty else { return fallback }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: region, format: .RGBAf,
                              colorSpace: Render.workingSpace)
        func value(_ p: CGPoint) -> SIMD3<Float>? {
            let ix = Int(p.x - region.minX), iy = Int(p.y - region.minY)
            guard ix >= 0, iy >= 0, ix < w, iy < h else { return nil }
            let i = ((h - 1 - iy) * w + ix) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        // mean normal
        var nx = 0.0, ny = 0.0
        for (_, n) in samples { nx += Double(n.x); ny += Double(n.y) }
        let nl = max(hypot(nx, ny), 1e-6)
        let navg = CGPoint(x: nx / nl, y: ny / nl)
        var best: (CGPoint, Float)?
        for side in [-1.0, 1.0] {
            for dist in [2.4, 3.2, 4.2, 5.4] {
                for tilt in [-0.35, 0.0, 0.35] {
                    let c = cos(tilt), s = sin(tilt)
                    let dir = CGPoint(x: navg.x * c - navg.y * s, y: navg.x * s + navg.y * c)
                    let o = CGPoint(x: dir.x * side * dist * r, y: dir.y * side * dist * r)
                    var cost: Float = 0, n = 0
                    for (p, nrm) in samples {
                        for sd in [-1.4, 1.4] {
                            let q = CGPoint(x: p.x + nrm.x * sd * r, y: p.y + nrm.y * sd * r)
                            guard let a = value(q), let b = value(CGPoint(x: q.x + o.x, y: q.y + o.y)) else { continue }
                            let d = a - b; cost += (d * d).sum(); n += 1
                        }
                        // Penalty if the moved stroke's center differs from its surroundings (another line)
                        if let ctr = value(CGPoint(x: p.x + o.x, y: p.y + o.y)),
                           let l = value(CGPoint(x: p.x + o.x + nrm.x * 1.4 * r, y: p.y + o.y + nrm.y * 1.4 * r)),
                           let rr = value(CGPoint(x: p.x + o.x - nrm.x * 1.4 * r, y: p.y + o.y - nrm.y * 1.4 * r)) {
                            let dd = ctr - (l + rr) / 2; cost += (dd * dd).sum() * 4
                        }
                    }
                    guard n > samples.count else { continue }
                    let norm = cost / Float(n)
                    if best == nil || norm < best!.1 {
                        best = (CGPoint(x: o.x / Double(scale), y: o.y / Double(scale)), norm)
                    }
                }
            }
        }
        return best?.0 ?? fallback
    }

    /// Radial weight, 1 up to the inner radius and 0 at the outer radius (grayscale).
    private static func radial(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ region: CGRect) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: c),
            "inputRadius0": r0, "inputRadius1": max(r1, r0 + 0.5),
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: region)
    }

    private static func multiply(_ a: CIImage, _ weight: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight]).cropped(to: a.extent)
    }

    // MARK: - Automatic source selection

    /// Picks, out of 16 positions, the one whose ring best matches the ring around the target. Compared on the CPU using the 1/8 preview.
    /// `small` is the decoded image scaled to guideScale (before retouching).
    static func pickSource(target: CGPoint, radius: Double, in small: CIImage, scale: CGFloat) -> CGPoint {
        let r = max(radius * Double(scale), 1.5)
        let t = CGPoint(x: target.x * scale, y: target.y * scale)
        let reach = r * 4.2
        let box = CGRect(x: t.x - reach - r * 2, y: t.y - reach - r * 2, width: (reach + r * 2) * 2,
                         height: (reach + r * 2) * 2).integral.intersection(small.extent)
        let w = Int(box.width), h = Int(box.height)
        guard w > 4, h > 4 else { return CGPoint(x: target.x + radius * 2.5, y: target.y) }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: box, format: .RGBAf,
                              colorSpace: Render.workingSpace)
        func value(_ x: Double, _ y: Double) -> SIMD3<Float>? {
            let ix = Int(x - Double(box.minX)), iy = Int(y - Double(box.minY))
            guard ix >= 0, iy >= 0, ix < w, iy < h else { return nil }
            // Render output fills from the top row.
            let i = ((h - 1 - iy) * w + ix) * 4
            return SIMD3(px[i], px[i + 1], px[i + 2])
        }
        // Compare 24 points on the ring.
        let ringPts = (0..<24).map { k -> (Double, Double) in
            let a = Double(k) / 24 * 2 * .pi
            return (cos(a) * r * 1.3, sin(a) * r * 1.3)
        }
        let tRing = ringPts.compactMap { value(Double(t.x) + $0.0, Double(t.y) + $0.1) }
        guard tRing.count == ringPts.count else { return CGPoint(x: target.x + radius * 2.5, y: target.y) }

        var best: (CGPoint, Float)?
        for dist in [2.3, 3.2, 4.1] {
            for k in 0..<8 {
                let a = Double(k) / 8 * 2 * .pi + dist
                let c = (Double(t.x) + cos(a) * r * dist, Double(t.y) + sin(a) * r * dist)
                let ring = ringPts.compactMap { value(c.0 + $0.0, c.1 + $0.1) }
                // The source center must be checked too (it must not be another dust spot).
                guard ring.count == ringPts.count, let centre = value(c.0, c.1) else { continue }
                var cost: Float = 0
                for (p, q) in zip(tRing, ring) { let d = p - q; cost += (d * d).sum() }
                let ringMean = ring.reduce(SIMD3<Float>(repeating: 0), +) / Float(ring.count)
                let dc = centre - ringMean
                cost += (dc * dc).sum() * 8
                if best == nil || cost < best!.1 {
                    best = (CGPoint(x: c.0 / Double(scale), y: c.1 / Double(scale)), cost)
                }
            }
        }
        return best?.0 ?? CGPoint(x: target.x + radius * 2.5, y: target.y)
    }
}
