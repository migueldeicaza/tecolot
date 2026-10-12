//
// WireHash.swift
// TecolotWire
//
// A 64-bit content hash for row versions. Only the helper computes it; the
// client treats versions as opaque values. The mixing follows the xxHash64
// short-input path, applied to every length.
//

public enum WireHash {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always)
    private static func rotl(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }

    public static func hash64(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBufferPointer { hash64($0, seed: seed) }
    }

    public static func hash64(_ bytes: UnsafeBufferPointer<UInt8>, seed: UInt64 = 0) -> UInt64 {
        let count = bytes.count
        var hash = seed &+ prime5 &+ UInt64(count)
        var index = 0
        guard let base = bytes.baseAddress else { return avalanche(hash) }
        let raw = UnsafeRawPointer(base)
        while index + 8 <= count {
            let word = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt64.self))
            hash ^= rotl(word &* prime2, 31) &* prime1
            hash = rotl(hash, 27) &* prime1 &+ prime4
            index += 8
        }
        if index + 4 <= count {
            let word = UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
            hash ^= word &* prime1
            hash = rotl(hash, 23) &* prime2 &+ prime3
            index += 4
        }
        while index < count {
            hash ^= UInt64(base[index]) &* prime5
            hash = rotl(hash, 11) &* prime1
            index += 1
        }
        return avalanche(hash)
    }

    @inline(__always)
    private static func avalanche(_ value: UInt64) -> UInt64 {
        var hash = value
        hash ^= hash >> 33
        hash = hash &* prime2
        hash ^= hash >> 29
        hash = hash &* prime3
        hash ^= hash >> 32
        return hash
    }
}
