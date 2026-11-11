import Foundation

/// xxHash-64 med frö 0, branschens vanliga checksumma för film. Går att mata i bitar, så att stora filer inte behöver ligga i minnet.
/// Skyddar mot fel i kopior, inte mot någon som medvetet förfalskar en fil.
struct XXH64 {
    private static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    private var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
    private var total: UInt64 = 0
    private var tail: [UInt8] = []

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 { rotl(acc &+ input &* p2, 31) &* p1 }
    @inline(__always) private static func merge(_ h: UInt64, _ v: UInt64) -> UInt64 { (h ^ round(0, v)) &* p1 &+ p4 }

    private mutating func stripe(_ raw: UnsafeRawBufferPointer, at i: Int) {
        v1 = Self.round(v1, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
        v2 = Self.round(v2, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)))
        v3 = Self.round(v3, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)))
        v4 = Self.round(v4, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)))
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            total &+= UInt64(raw.count)
            var i = 0
            if !tail.isEmpty {
                i = min(32 - tail.count, raw.count)
                tail.append(contentsOf: raw[0..<i])
                guard tail.count == 32 else { return }
                let full = tail
                full.withUnsafeBytes { stripe($0, at: 0) }
                tail.removeAll(keepingCapacity: true)
            }
            // Lokala variabler: det här är loopen som avgör hastigheten på stora filer.
            var a = v1, b = v2, c = v3, d = v4
            while i + 32 <= raw.count {
                a = Self.round(a, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                b = Self.round(b, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)))
                c = Self.round(c, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)))
                d = Self.round(d, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)))
                i += 32
            }
            v1 = a; v2 = b; v3 = c; v4 = d
            if i < raw.count { tail.append(contentsOf: raw[i...]) }
        }
    }

    func finalize() -> UInt64 {
        typealias X = XXH64
        var h: UInt64
        if total >= 32 {
            h = X.rotl(v1, 1) &+ X.rotl(v2, 7) &+ X.rotl(v3, 12) &+ X.rotl(v4, 18)
            for v in [v1, v2, v3, v4] { h = X.merge(h, v) }
        } else {
            h = X.p5
        }
        h &+= total
        tail.withUnsafeBytes { raw in
            var i = 0
            while i + 8 <= raw.count {
                h = X.rotl(h ^ X.round(0, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))), 27) &* X.p1 &+ X.p4
                i += 8
            }
            if i + 4 <= raw.count {
                h = X.rotl(h ^ UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* X.p1, 23) &* X.p2 &+ X.p3
                i += 4
            }
            while i < raw.count {
                h = X.rotl(h ^ UInt64(raw[i]) &* X.p5, 11) &* X.p1
                i += 1
            }
        }
        h ^= h >> 33; h = h &* X.p2
        h ^= h >> 29; h = h &* X.p3
        return h ^ (h >> 32)
    }
}

/// Kända facit för xxHash-64, och samma svar oavsett hur filen delas upp vid läsningen.
func testXXH64() {
    func hash(_ d: Data) -> UInt64 { var x = XXH64(); x.update(d); return x.finalize() }
    let known: [(String, UInt64)] = [
        ("", 0xEF46_DB37_51D8_E999),
        ("a", 0xD24E_C4F1_A98C_6E5B),
        ("abc", 0x44BC_2CF5_AD77_0999),
        ("xxhash", 0x32DD_3895_2C4B_C720),
        ("Nobody inspects the spammish repetition", 0xFBCE_A83C_8A37_8BF1),
    ]
    for (text, want) in known { assert(hash(Data(text.utf8)) == want, "xxh64(\(text))") }

    var bytes = Data(count: 1 << 20)
    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
    let whole = hash(bytes)
    for size in [1, 7, 31, 32, 33, 4096, 65_537] {
        var x = XXH64(), i = 0
        while i < bytes.count { let end = min(i + size, bytes.count); x.update(bytes[i..<end]); i = end }
        assert(x.finalize() == whole, "uppdelning i \(size) byte ska ge samma svar")
    }
    var changed = bytes
    changed[changed.count / 2] ^= 1
    assert(hash(changed) != whole, "en ändrad bit ska ge en annan checksumma")
}
