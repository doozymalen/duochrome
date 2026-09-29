import CoreImage
import Metal
import Foundation

/// Base look: a 3D look table applied right after RAW decoding (before user adjustments).
///
/// "Camera-fitted" is a table matched pixel by pixel to hundreds of reference renders. Fitted per camera, so it only applies to cameras with a table.
///
/// The table operates on 0–1 values encoded in gamma 2.2. Bright values above 1.0 add back whatever overflowed the table,
/// keeping highlight recovery headroom.
enum Look {
    static let titles = ["Apple 기본", "카메라 맞춤"]

    /// Camera name → look table file name. Put `name.lut` in the Looks folder to apply it to that camera (case-insensitive).
    /// e.g. "Canon EOS R5m2" → CanonEOSR5m2, "NIKON CORPORATION NIKON Z 8" → NIKONZ8, "SONY ILCE-7M4" → SONYILCE7M4
    static func file(for camera: String) -> String? {
        let key = fileKey(camera)
        guard !key.isEmpty else { return nil }
        return lutNames().first { $0.lowercased() == key.lowercased() }
    }

    /// Drops corporate suffixes (CORPORATION etc.) and repeated vendor names, keeping letters and digits only
    static func fileKey(_ camera: String) -> String {
        let noise: Set<String> = ["corporation", "corp", "corp.", "co.,ltd.", "co.,ltd", "co.", "ltd", "ltd.", "imaging", "inc", "inc."]
        var words: [String] = []
        for w in camera.split(separator: " ").map(String.init) where !noise.contains(w.lowercased()) {
            if words.contains(where: { $0.lowercased() == w.lowercased() }) { continue }
            words.append(w)
        }
        return String(words.joined().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    private static var names: [String]?

    /// Look table names in the app bundle's and the repo's Looks folders (without extension)
    private static func lutNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let names { return names }
        var out: [String] = []
        for dir in lookDirs() {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for u in files where u.pathExtension.lowercased() == "lut" {
                let n = u.deletingPathExtension().lastPathComponent
                if !out.contains(n) { out.append(n) }
            }
        }
        names = out
        return out
    }

    private static func lookDirs() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Looks")) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("Resources/Looks"))
        return dirs
    }

    static func available(for camera: String) -> Bool { file(for: camera).flatMap(cube) != nil }

    /// Whether any look table exists (if none, the "Camera-fitted" option is hidden)
    static var anyAvailable: Bool { !lutNames().isEmpty }

    private static var cache: [String: (n: Int, data: Data)?] = [:]
    private static let lock = NSLock()

    /// Reads from Resources/Looks in the app bundle, or the repo's Resources/Looks during development.
    static func cube(_ name: String) -> (n: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let urls = lookDirs().map { $0.appendingPathComponent("\(name).lut") }
        var result: (Int, Data)?
        for u in urls {
            guard let d = try? Data(contentsOf: u), d.count > 8, d.prefix(4) == Data("S1LT".utf8) else { continue }
            let n = Int(d.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })
            let body = d.subdata(in: 8..<d.count)
            guard body.count == n * n * n * 16 else { continue }
            result = (n, body)
            break
        }
        cache[name] = result
        return result
    }

    static func apply(_ img: CIImage, look: Float, camera: String) -> CIImage {
        guard look >= 0.5, let name = file(for: camera), let (n, data) = cube(name), !img.extent.isInfinite,
              let tex = texture(name, n: n, data: data) else { return img }
        let e = img.extent
        // Encode → 3D table → restore in one kernel. With a Core Image color cube in between,
        // rendering the photo region applied the color conversion to the background again and margins bled black.
        do {
            return try LookOp.apply(withExtent: e, inputs: [img], arguments: ["lut": tex, "extent": e]).cropped(to: e)
        } catch {
            NSLog("기본 모습 실패: \(error)")
            return img
        }
    }

    private static var textures: [String: MTLTexture] = [:]

    /// Look table as a 3D texture (built once).
    static func texture(_ name: String, n: Int, data: Data) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = textures[name] { return t }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = n; d.height = n; d.depth = n
        d.usage = [.shaderRead]
        guard let t = Render.device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                      bytesPerRow: n * 16, bytesPerImage: n * n * 16)
        }
        textures[name] = t
        return t
    }

    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    // linear → clamp to 0–1, gamma 2.2 → 3D table (trilinear) → decode gamma + add back overflow above 1.0
    kernel void look_apply(texture2d<half, access::read> src [[texture(0)]],
                           texture3d<float, access::sample> lut [[texture(1)]],
                           texture2d<half, access::write> dst [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float4 c = float4(src.read(gid));
        float3 enc = pow(clamp(c.rgb, 0.0, 1.0), 1.0 / 2.2);
        float n = float(lut.get_width());
        float3 uvw = (enc * (n - 1.0) + 0.5) / n;
        float3 m = lut.sample(s, uvw).rgb;
        float3 lin = pow(max(m, 0.0), 2.2) + max(c.rgb - 1.0, 0.0);
        dst.write(half4(half3(lin), 1), gid);
    }
    """

    static let pipeline: MTLComputePipelineState = {
        let lib = try! Render.device.makeLibrary(source: kernelSource, options: nil)
        return try! Render.device.makeComputePipelineState(function: lib.makeFunction(name: "look_apply")!)
    }()
}

final class LookOp: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let buffer = output.metalCommandBuffer, let dst = output.metalTexture,
              let lut = arguments?["lut"] as? MTLTexture else { return }
        let src = PixelOp.aligned(input, to: output, buffer: buffer, size: (dst.width, dst.height))
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        let pso = Look.pipeline
        encoder.setComputePipelineState(pso)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(lut, index: 1)
        encoder.setTexture(dst, index: 2)
        let w = pso.threadExecutionWidth, h = pso.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        PixelOp.clearOutside(dst, region: output.region, extent: arguments?["extent"] as? CGRect, buffer: buffer)
    }
}
