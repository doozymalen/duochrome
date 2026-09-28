import Foundation
import Compression

/// PSD·PSB 파일 형식 (공개된 파일 형식 명세).
/// 이 파일은 바이트 단위 읽기·쓰기만 한다. 레이어로 바꾸기는 PSDImport.swift, 문서에서 만들기는 PSDExport.swift.
enum PSD {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Channel {
        var id: Int16
        /// 0 그대로, 1 RLE(PackBits), 2 ZIP, 3 ZIP+예측
        var compression: UInt16 = 0
        var payload = Data()
    }

    struct Mask {
        var top: Int32 = 0, left: Int32 = 0, bottom: Int32 = 0, right: Int32 = 0
        var defaultColor: UInt8 = 0
        var flags: UInt8 = 0
        var disabled: Bool { flags & 2 != 0 }
        var width: Int { Int(right - left) }
        var height: Int { Int(bottom - top) }
    }

    struct Layer {
        var top: Int32 = 0, left: Int32 = 0, bottom: Int32 = 0, right: Int32 = 0
        var channels: [Channel] = []
        var blend = "norm"
        var opacity: UInt8 = 255
        var clipping: UInt8 = 0
        var flags: UInt8 = 0
        var mask: Mask?
        var blendingRanges = Data()
        var name = ""
        var blocks: [(key: String, data: Data)] = []

        var width: Int { Int(right - left) }
        var height: Int { Int(bottom - top) }
        var visible: Bool { flags & 2 == 0 }
        func block(_ key: String) -> Data? { blocks.first { $0.key == key }?.data }
        /// 그룹 표시: 1·2 열린·닫힌 폴더(그룹 맨 위), 3 그룹 끝(맨 아래 구분자). 없으면 nil.
        var section: Int? {
            guard let d = block("lsct") ?? block("lsdk"), d.count >= 4 else { return nil }
            var r = Reader(d)
            let t = Int((try? r.u32()) ?? 0)
            return t == 0 ? nil : t
        }
        var sectionBlend: String? {
            guard let d = block("lsct") ?? block("lsdk"), d.count >= 12 else { return nil }
            return String(decoding: d[d.startIndex + 8 ..< d.startIndex + 12], as: UTF8.self)
        }
        var unicodeName: String {
            if let d = block("luni"), var r = Optional(Reader(d)), let s = try? r.unicode() { return s }
            return name
        }
        func channel(_ id: Int16) -> Channel? { channels.first { $0.id == id } }
    }

    struct File {
        var version = 1
        var channelCount = 3
        var width = 0, height = 0
        var depth = 8
        /// 0 비트맵, 1 회색조, 2 인덱스, 3 RGB, 4 CMYK, 7 다채널, 8 이중톤, 9 Lab
        var mode = 3
        var colorModeData = Data()
        var resources: [(id: UInt16, data: Data)] = []
        var layers: [Layer] = []
        var hasMergedAlpha = false
        var globalBlocks: [(key: String, data: Data)] = []
        var mergedCompression: UInt16 = 0
        var merged = Data()

        var isPSB: Bool { version == 2 }
        var icc: Data? { resources.first { $0.id == 1039 }?.data }
        func globalBlock(_ key: String) -> Data? { globalBlocks.first { $0.key == key }?.data }
    }

    // MARK: - 바이트 읽기

    struct Reader {
        let data: Data
        var pos: Int
        init(_ d: Data) { data = d; pos = d.startIndex }
        var remaining: Int { data.endIndex - pos }
        var atEnd: Bool { pos >= data.endIndex }

        mutating func need(_ n: Int) throws {
            guard n >= 0, pos + n <= data.endIndex else { throw Failure(message: "PSD 파일이 잘렸습니다 (\(pos - data.startIndex)바이트 위치)") }
        }
        mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return data[pos] }
        mutating func u16() throws -> UInt16 {
            try need(2); defer { pos += 2 }
            return UInt16(data[pos]) << 8 | UInt16(data[pos + 1])
        }
        mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
        mutating func u32() throws -> UInt32 {
            try need(4); defer { pos += 4 }
            return UInt32(data[pos]) << 24 | UInt32(data[pos + 1]) << 16 | UInt32(data[pos + 2]) << 8 | UInt32(data[pos + 3])
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func bytes(_ n: Int) throws -> Data { try need(n); defer { pos += n }; return data[pos ..< pos + n] }
        mutating func skip(_ n: Int) throws { try need(n); pos += n }
        mutating func key() throws -> String { String(decoding: try bytes(4), as: UTF8.self) }
        /// 길이(PSB면 몇몇 곳은 8바이트)
        mutating func len(_ big: Bool) throws -> Int { big ? Int(try u64()) : Int(try u32()) }
        /// 파스칼 문자열, 전체 길이를 `pad`의 배수로 맞춘다
        mutating func pascal(pad: Int) throws -> String {
            let n = Int(try u8())
            let s = try bytes(n)
            let total = n + 1
            let padded = (total + pad - 1) / pad * pad
            try skip(padded - total)
            // 맥 로만(옛 파일) 또는 UTF-8
            return String(data: s, encoding: .utf8) ?? String(data: s, encoding: .macOSRoman) ?? ""
        }
        /// 유니코드 문자열: 글자 수(4바이트) + UTF-16BE
        mutating func unicode() throws -> String {
            let n = Int(try u32())
            let d = try bytes(n * 2)
            var s = String(data: d, encoding: .utf16BigEndian) ?? ""
            while s.hasSuffix("\0") { s.removeLast() }
            return s
        }
        /// 설명자 키: 길이 0이면 4바이트 키
        mutating func id() throws -> String {
            let n = Int(try u32())
            return String(decoding: try bytes(n == 0 ? 4 : n), as: UTF8.self)
        }
    }

    // MARK: - 바이트 쓰기

    struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
        mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
        mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
        mutating func f64(_ v: Double) { u64(v.bitPattern) }
        mutating func len(_ v: Int, _ big: Bool) { if big { u64(UInt64(v)) } else { u32(UInt32(v)) } }
        mutating func key(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4)) + Array(repeating: 32, count: max(0, 4 - s.utf8.count))) }
        mutating func bytes(_ d: Data) { data.append(d) }
        mutating func pad(_ multiple: Int, from start: Int) { while (data.count - start) % multiple != 0 { data.append(0) } }
        mutating func pascal(_ s: String, pad: Int) {
            let b = Array(s.utf8.prefix(255))
            u8(UInt8(b.count)); data.append(contentsOf: b)
            let total = b.count + 1
            for _ in 0 ..< ((total + pad - 1) / pad * pad - total) { u8(0) }
        }
        mutating func unicode(_ s: String) {
            let u = Array(s.utf16) + [0]
            u32(UInt32(u.count))
            for c in u { u16(c) }
        }
        mutating func id(_ s: String) {
            if s.utf8.count == 4 { u32(0); key(s) } else { u32(UInt32(s.utf8.count)); data.append(contentsOf: Array(s.utf8)) }
        }
    }

    // MARK: - 파일 읽기

    /// 8B64로 쓰는 긴 길이 블록 (PSB에서만 8바이트)
    static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

    static func read(_ url: URL) throws -> File {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data)
    }

    static func read(_ data: Data) throws -> File {
        var r = Reader(data)
        var f = File()
        guard try r.key() == "8BPS" else { throw Failure(message: "PSD 파일이 아닙니다") }
        f.version = Int(try r.u16())
        guard f.version == 1 || f.version == 2 else { throw Failure(message: "알 수 없는 PSD 판 \(f.version)") }
        try r.skip(6)
        f.channelCount = Int(try r.u16())
        f.height = Int(try r.u32())
        f.width = Int(try r.u32())
        f.depth = Int(try r.u16())
        f.mode = Int(try r.u16())
        let big = f.isPSB
        // 색 모드 자료
        let cm = Int(try r.u32())
        f.colorModeData = try r.bytes(cm)
        // 이미지 자원
        let resLen = Int(try r.u32())
        var rr = Reader(try r.bytes(resLen))
        while rr.remaining >= 12 {
            guard try rr.key() == "8BIM" else { break }
            let id = try rr.u16()
            _ = try rr.pascal(pad: 2)
            let n = Int(try rr.u32())
            let d = try rr.bytes(n)
            if n % 2 == 1 { try? rr.skip(1) }
            f.resources.append((id, d))
        }
        // 레이어와 마스크 정보
        let lmLen = try r.len(big)
        let lmEnd = r.pos + lmLen
        if lmLen > 0 {
            let liLen = try r.len(big)
            let liEnd = r.pos + liLen
            if liLen > 0 {
                var lr = Reader(try r.bytes(liLen))
                (f.layers, f.hasMergedAlpha) = try readLayerInfo(&lr, big: big)
            }
            r.pos = liEnd
            // 전역 레이어 마스크
            if r.pos + 4 <= lmEnd {
                let g = Int(try r.u32())
                try r.skip(min(g, lmEnd - r.pos))
            }
            // 문서 단위 추가 정보 (16·32비트 문서는 레이어가 Lr16·Lr32 안에 있다)
            while r.pos + 12 <= lmEnd {
                let sig = try r.key()
                guard sig == "8BIM" || sig == "8B64" else { break }
                let k = try r.key()
                let n = try r.len(big && longKeys.contains(k))
                let d = try r.bytes(min(n, lmEnd - r.pos))
                f.globalBlocks.append((k, d))
                syncToSignature(&r, end: lmEnd)
                if (k == "Lr16" || k == "Lr32"), f.layers.isEmpty {
                    var lr = Reader(d)
                    (f.layers, f.hasMergedAlpha) = try readLayerInfo(&lr, big: big)
                }
            }
        }
        r.pos = lmEnd
        // 합친 그림
        if r.remaining >= 2 {
            f.mergedCompression = try r.u16()
            f.merged = r.data[r.pos ..< r.data.endIndex]
        }
        return f
    }

    /// 블록 뒤 채움 바이트(쓴 프로그램마다 2 또는 4의 배수)를 건너 다음 서명에 맞춘다
    private static func syncToSignature(_ r: inout Reader, end: Int) {
        for skip in 0 ... 3 {
            let p = r.pos + skip
            guard p + 4 <= end else { break }
            let k = String(decoding: r.data[p ..< p + 4], as: UTF8.self)
            if k == "8BIM" || k == "8B64" { r.pos = p; return }
        }
    }

    private static func readLayerInfo(_ r: inout Reader, big: Bool) throws -> ([Layer], Bool) {
        let rawCount = try r.i16()
        let count = Int(abs(Int(rawCount)))
        var layers: [Layer] = []
        var lengths: [[Int]] = []
        for _ in 0 ..< count {
            var l = Layer()
            l.top = try r.i32(); l.left = try r.i32(); l.bottom = try r.i32(); l.right = try r.i32()
            let nc = Int(try r.u16())
            var lens: [Int] = []
            for _ in 0 ..< nc {
                let id = try r.i16()
                lens.append(try r.len(big))
                l.channels.append(Channel(id: id))
            }
            guard try r.key() == "8BIM" else { throw Failure(message: "레이어 기록이 깨졌습니다") }
            l.blend = try r.key()
            l.opacity = try r.u8()
            l.clipping = try r.u8()
            l.flags = try r.u8()
            _ = try r.u8()
            let extra = Int(try r.u32())
            let extraEnd = r.pos + extra
            // 레이어 마스크
            let ml = Int(try r.u32())
            if ml >= 18 {
                var m = Mask()
                let start = r.pos
                m.top = try r.i32(); m.left = try r.i32(); m.bottom = try r.i32(); m.right = try r.i32()
                m.defaultColor = try r.u8()
                m.flags = try r.u8()
                l.mask = m
                r.pos = start + ml
            } else {
                try r.skip(ml)
            }
            let br = Int(try r.u32())
            l.blendingRanges = try r.bytes(br)
            l.name = try r.pascal(pad: 4)
            while r.pos + 12 <= extraEnd {
                let sig = try r.key()
                guard sig == "8BIM" || sig == "8B64" else { break }
                let k = try r.key()
                let n = try r.len(big && longKeys.contains(k))
                let d = try r.bytes(min(n, extraEnd - r.pos))
                l.blocks.append((k, d))
                syncToSignature(&r, end: extraEnd)
            }
            r.pos = extraEnd
            layers.append(l)
            lengths.append(lens)
        }
        // 채널 그림 자료
        for i in 0 ..< layers.count {
            for c in 0 ..< layers[i].channels.count {
                let n = lengths[i][c]
                guard n >= 2 else { try r.skip(max(n, 0)); continue }
                layers[i].channels[c].compression = try r.u16()
                layers[i].channels[c].payload = try r.bytes(n - 2)
            }
        }
        return (layers, rawCount < 0)
    }

    // MARK: - 채널 풀기

    /// 채널 하나를 평면 바이트(빅엔디언)로 푼다. 없거나 깨졌으면 nil.
    static func decode(_ ch: Channel, width w: Int, height h: Int, depth: Int, big: Bool) -> [UInt8]? {
        guard w > 0, h > 0 else { return nil }
        let bpp = max(depth / 8, 1)
        let rowBytes = depth == 1 ? (w + 7) / 8 : w * bpp
        let total = rowBytes * h
        switch ch.compression {
        case 0:
            guard ch.payload.count >= total else { return nil }
            return [UInt8](ch.payload.prefix(total))
        case 1:
            return unpackRLE(ch.payload, rows: h, rowBytes: rowBytes, big: big, countsInline: true)
        case 2, 3:
            guard var out = inflate(ch.payload, size: total) else { return nil }
            if ch.compression == 3 { unpredict(&out, width: w, height: h, depth: depth) }
            return out
        default:
            return nil
        }
    }

    /// 합친 그림의 채널들 (RLE면 모든 채널의 줄 길이가 앞에 모여 있다)
    static func mergedChannels(_ f: File) -> [[UInt8]] {
        let bpp = max(f.depth / 8, 1)
        let rowBytes = f.depth == 1 ? (f.width + 7) / 8 : f.width * bpp
        let plane = rowBytes * f.height
        let n = f.channelCount
        switch f.mergedCompression {
        case 0:
            return (0 ..< n).compactMap { c in
                let s = f.merged.startIndex + c * plane
                guard s + plane <= f.merged.endIndex else { return nil }
                return [UInt8](f.merged[s ..< s + plane])
            }
        case 1:
            var r = Reader(f.merged)
            var counts: [Int] = []
            for _ in 0 ..< n * f.height { counts.append(f.isPSB ? Int((try? r.u32()) ?? 0) : Int((try? r.u16()) ?? 0)) }
            var out: [[UInt8]] = []
            for c in 0 ..< n {
                var plane = [UInt8](); plane.reserveCapacity(rowBytes * f.height)
                for y in 0 ..< f.height {
                    let len = counts[c * f.height + y]
                    guard let row = try? r.bytes(len) else { return out }
                    plane.append(contentsOf: packBitsDecode(row, size: rowBytes))
                }
                out.append(plane)
            }
            return out
        case 2, 3:
            guard var all = inflate(f.merged, size: plane * n) else { return [] }
            if f.mergedCompression == 3 {
                for c in 0 ..< n {
                    var p = Array(all[c * plane ..< (c + 1) * plane])
                    unpredict(&p, width: f.width, height: f.height, depth: f.depth)
                    all.replaceSubrange(c * plane ..< (c + 1) * plane, with: p)
                }
            }
            return (0 ..< n).map { Array(all[$0 * plane ..< ($0 + 1) * plane]) }
        default:
            return []
        }
    }

    private static func unpackRLE(_ d: Data, rows: Int, rowBytes: Int, big: Bool, countsInline: Bool) -> [UInt8]? {
        var r = Reader(d)
        var counts: [Int] = []
        counts.reserveCapacity(rows)
        for _ in 0 ..< rows {
            guard let c = big ? (try? r.u32()).map(Int.init) : (try? r.u16()).map(Int.init) else { return nil }
            counts.append(c)
        }
        var out = [UInt8](); out.reserveCapacity(rows * rowBytes)
        for c in counts {
            guard let row = try? r.bytes(c) else { return nil }
            out.append(contentsOf: packBitsDecode(row, size: rowBytes))
        }
        return out
    }

    static func packBitsDecode(_ d: Data, size: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(size)
        var i = d.startIndex
        while i < d.endIndex, out.count < size {
            let n = Int(Int8(bitPattern: d[i])); i += 1
            if n >= 0 {
                let e = min(i + n + 1, d.endIndex)
                out.append(contentsOf: d[i ..< e]); i = e
            } else if n != -128 {
                guard i < d.endIndex else { break }
                out.append(contentsOf: repeatElement(d[i], count: 1 - n)); i += 1
            }
        }
        if out.count < size { out.append(contentsOf: repeatElement(0, count: size - out.count)) }
        if out.count > size { out.removeLast(out.count - size) }
        return out
    }

    static func packBitsEncode(_ row: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) {
        let n = row.count
        var i = 0
        while i < n {
            // 같은 값이 이어지면 반복으로
            var run = 1
            while i + run < n, run < 128, row[i + run] == row[i] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run))); out.append(row[i]); i += run; continue
            }
            // 날 값 묶음: 반복 3개가 시작되기 전까지
            var lit = 0
            while i + lit < n, lit < 128 {
                if i + lit + 2 < n, row[i + lit] == row[i + lit + 1], row[i + lit] == row[i + lit + 2] { break }
                lit += 1
            }
            out.append(UInt8(lit - 1))
            for k in 0 ..< lit { out.append(row[i + k]) }
            i += lit
        }
    }

    /// zlib(2바이트 머리 + deflate) 풀기
    static func inflate(_ d: Data, size: Int) -> [UInt8]? {
        guard d.count > 2 else { return nil }
        let body = d.dropFirst(2)
        var out = [UInt8](repeating: 0, count: size)
        let n = body.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == size ? out : (n > 0 ? out : nil)
    }

    /// zlib로 싸기 (머리 78 9C + deflate + adler32)
    static func deflate(_ bytes: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: bytes.count + bytes.count / 8 + 1024)
        let n = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let e = min(i + 5552, bytes.count)
            for k in i ..< e { a += UInt32(bytes[k]); b += a }
            a %= 65521; b %= 65521
            i = e
        }
        var d = Data([0x78, 0x9C])
        d.append(contentsOf: out[0 ..< n])
        let ad = b << 16 | a
        d.append(contentsOf: [UInt8(ad >> 24), UInt8((ad >> 16) & 0xff), UInt8((ad >> 8) & 0xff), UInt8(ad & 0xff)])
        return d
    }

    /// ZIP 예측(가로 차분) 되돌리기
    private static func unpredict(_ p: inout [UInt8], width w: Int, height h: Int, depth: Int) {
        switch depth {
        case 8:
            for y in 0 ..< h { let o = y * w; for x in 1 ..< w { p[o + x] = p[o + x] &+ p[o + x - 1] } }
        case 16:
            for y in 0 ..< h {
                let o = y * w * 2
                var prev = UInt16(p[o]) << 8 | UInt16(p[o + 1])
                for x in 1 ..< w {
                    let i = o + x * 2
                    let v = (UInt16(p[i]) << 8 | UInt16(p[i + 1])) &+ prev
                    p[i] = UInt8(v >> 8); p[i + 1] = UInt8(v & 0xff); prev = v
                }
            }
        case 32:
            // 바이트 차분 뒤 한 줄의 바이트를 (모든 픽셀의 1번째 바이트, 2번째, …) 순으로 섞어 둔다
            let rb = w * 4
            for y in 0 ..< h {
                let o = y * rb
                for x in 1 ..< rb { p[o + x] = p[o + x] &+ p[o + x - 1] }
                let row = Array(p[o ..< o + rb])
                for x in 0 ..< w { for k in 0 ..< 4 { p[o + x * 4 + k] = row[k * w + x] } }
            }
        default: break
        }
    }

    // MARK: - 설명자 (Action Descriptor)

    indirect enum Value {
        case double(Double), unit(String, Double), text(String), enumerated(String, String), int(Int)
        case bool(Bool), object(Descriptor), list([Value]), raw(Data), cls(String), units(String, [Double]), reference

        var double: Double? {
            switch self { case .double(let d): return d; case .unit(_, let d): return d; case .int(let i): return Double(i); default: return nil }
        }
        var int: Int? { if case .int(let i) = self { return i }; return double.map { Int($0) } }
        var string: String? { if case .text(let s) = self { return s }; return nil }
        var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
        var object: Descriptor? { if case .object(let o) = self { return o }; return nil }
        var list: [Value]? { if case .list(let l) = self { return l }; return nil }
        var enumValue: String? { if case .enumerated(_, let e) = self { return e }; return nil }
        var rawData: Data? { if case .raw(let d) = self { return d }; return nil }
        var unitName: String? { if case .unit(let u, _) = self { return u }; return nil }
    }

    /// (클래스인 까닭: 구조체면 Value와 서로 품어서 컴파일러가 순환 참조로 멈춘다)
    final class Descriptor {
        var name = ""
        var cls = ""
        var items: [(key: String, value: Value)] = []
        init(name: String = "", cls: String = "", items: [(key: String, value: Value)] = []) {
            self.name = name; self.cls = cls; self.items = items
        }
        subscript(_ k: String) -> Value? { items.first { $0.key == k }?.value }
        func double(_ k: String) -> Double? { self[k]?.double }
        func obj(_ k: String) -> Descriptor? { self[k]?.object }
        /// 'Clr ' 같은 색 객체 → 0~1 RGB
        static func rgb(_ d: Descriptor?) -> [Float]? {
            guard let d else { return nil }
            if let r = d.double("Rd  "), let g = d.double("Grn "), let b = d.double("Bl  ") {
                return [Float(r / 255), Float(g / 255), Float(b / 255)]
            }
            if let r = d.double("redFloat"), let g = d.double("greenFloat"), let b = d.double("blueFloat") {
                return [Float(r), Float(g), Float(b)]
            }
            if let g = d.double("Gry ") { let v = Float(1 - g / 100); return [v, v, v] }
            return nil
        }
    }

    static func descriptor(_ r: inout Reader) throws -> Descriptor {
        let d = Descriptor()
        d.name = try r.unicode()
        d.cls = try r.id()
        let n = Int(try r.u32())
        for _ in 0 ..< n {
            let k = try r.id()
            d.items.append((k, try value(&r)))
        }
        return d
    }

    static func value(_ r: inout Reader) throws -> Value {
        let t = try r.key()
        switch t {
        case "Objc", "GlbO": return .object(try descriptor(&r))
        case "VlLs":
            let n = Int(try r.u32())
            var l: [Value] = []
            for _ in 0 ..< n { l.append(try value(&r)) }
            return .list(l)
        case "doub": return .double(try r.f64())
        case "UntF": let u = try r.key(); return .unit(u, try r.f64())
        case "UnFl":
            let u = try r.key(); let n = Int(try r.u32())
            var v: [Double] = []
            for _ in 0 ..< n { v.append(try r.f64()) }
            return .units(u, v)
        case "TEXT": return .text(try r.unicode())
        case "enum": let ty = try r.id(); return .enumerated(ty, try r.id())
        case "long": return .int(Int(try r.i32()))
        case "comp": return .int(Int(Int64(bitPattern: try r.u64())))
        case "bool": return .bool(try r.u8() != 0)
        case "type", "GlbC": _ = try r.unicode(); return .cls(try r.id())
        case "alis", "Pth ": let n = Int(try r.u32()); return .raw(try r.bytes(n))
        case "tdta": let n = Int(try r.u32()); return .raw(try r.bytes(n))
        case "obj ":
            let n = Int(try r.u32())
            for _ in 0 ..< n {
                switch try r.key() {
                case "prop": _ = try r.unicode(); _ = try r.id(); _ = try r.id()
                case "Clss": _ = try r.unicode(); _ = try r.id()
                case "Enmr": _ = try r.unicode(); _ = try r.id(); _ = try r.id(); _ = try r.id()
                case "rele": _ = try r.unicode(); _ = try r.id(); _ = try r.u32()
                case "Idnt", "indx": _ = try r.u32()
                case "name": _ = try r.unicode(); _ = try r.id(); _ = try r.unicode()
                default: throw Failure(message: "알 수 없는 참조")
                }
            }
            return .reference
        case "ObAr":
            // 객체 배열 (글자 변형 등): 항목 수, 이름, 클래스, 키마다 단위 배열
            _ = try r.u32()
            _ = try r.unicode(); _ = try r.id()
            let n = Int(try r.u32())
            let d = Descriptor()
            for _ in 0 ..< n {
                let k = try r.id()
                let ty = try r.key()
                if ty == "UnFl" {
                    let u = try r.key(); let c = Int(try r.u32())
                    var v: [Double] = []
                    for _ in 0 ..< c { v.append(try r.f64()) }
                    d.items.append((k, .units(u, v)))
                } else { throw Failure(message: "알 수 없는 객체 배열 \(ty)") }
            }
            return .object(d)
        default:
            throw Failure(message: "알 수 없는 설명자 형식 \(t)")
        }
    }

    /// 버전(4바이트) 뒤에 설명자가 오는 블록
    static func versionedDescriptor(_ d: Data) -> Descriptor? {
        var r = Reader(d)
        guard (try? r.u32()) != nil else { return nil }
        return try? descriptor(&r)
    }

    // 설명자 쓰기 (필요한 형식만)
    static func write(_ d: Descriptor, _ w: inout Writer) {
        w.unicode(d.name)
        w.id(d.cls)
        w.u32(UInt32(d.items.count))
        for (k, v) in d.items { w.id(k); write(v, &w) }
    }

    static func write(_ v: Value, _ w: inout Writer) {
        switch v {
        case .object(let o): w.key("Objc"); write(o, &w)
        case .list(let l): w.key("VlLs"); w.u32(UInt32(l.count)); for x in l { write(x, &w) }
        case .double(let d): w.key("doub"); w.f64(d)
        case .unit(let u, let d): w.key("UntF"); w.key(u); w.f64(d)
        case .text(let s): w.key("TEXT"); w.unicode(s)
        case .enumerated(let t, let e): w.key("enum"); w.id(t); w.id(e)
        case .int(let i): w.key("long"); w.i32(Int32(clamping: i))
        case .bool(let b): w.key("bool"); w.u8(b ? 1 : 0)
        case .raw(let d): w.key("tdta"); w.u32(UInt32(d.count)); w.bytes(d)
        case .cls(let c): w.key("type"); w.unicode(""); w.id(c)
        case .units(let u, let a): w.key("UnFl"); w.key(u); w.u32(UInt32(a.count)); for x in a { w.f64(x) }
        case .reference: break
        }
    }

    // MARK: - 블렌드 키

    static let blendKeys: [(psd: String, ours: String)] = [
        ("norm", "normal"), ("diss", "dissolve"), ("dark", "darken"), ("mul ", "multiply"), ("idiv", "colorBurn"),
        ("lbrn", "linearBurn"), ("dkCl", "darkerColor"), ("lite", "lighten"), ("scrn", "screen"), ("div ", "colorDodge"),
        ("lddg", "linearDodge"), ("lgCl", "lighterColor"), ("over", "overlay"), ("sLit", "softLight"), ("hLit", "hardLight"),
        ("vLit", "vividLight"), ("lLit", "linearLight"), ("pLit", "pinLight"), ("hMix", "hardMix"), ("diff", "difference"),
        ("smud", "exclusion"), ("fsub", "subtract"), ("fdiv", "divide"), ("hue ", "hue"), ("sat ", "saturation"),
        ("colr", "color"), ("lum ", "luminosity"), ("pass", "passThrough"),
    ]
    static func ourBlend(_ k: String) -> String { blendKeys.first { $0.psd == k }?.ours ?? "normal" }
    static func psdBlend(_ s: String) -> String { blendKeys.first { $0.ours == s }?.psd ?? "norm" }
}
