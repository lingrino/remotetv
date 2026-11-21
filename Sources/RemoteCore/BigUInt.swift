/// Just enough unsigned big-integer arithmetic for SRP-6a over the 3072-bit HAP group:
/// big-endian byte conversion, add/sub/mul/compare, and modular exponentiation with
/// Montgomery multiplication. Little-endian 64-bit limbs, no leading-zero invariant
/// (functions trim where it matters). Runs once per pairing, never on a hot path; not
/// constant-time (the secrets involved are ephemeral and the peer is on the LAN).
struct BigUInt: Equatable {
    var limbs: [UInt64]

    init(limbs: [UInt64]) { self.limbs = limbs.isEmpty ? [0] : limbs }

    init(_ v: UInt64) { limbs = [v] }

    /// From big-endian bytes (any length, leading zeros allowed).
    init(bytes: some Collection<UInt8>) {
        let b = Array(bytes)
        var out = [UInt64](repeating: 0, count: max(1, (b.count + 7) / 8))
        for (k, byte) in b.reversed().enumerated() {
            out[k / 8] |= UInt64(byte) << (UInt64(k % 8) * 8)
        }
        self.init(limbs: out)
    }

    init?(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex.utf8.filter { $0 != 32 && $0 != 10 })
        if chars.count % 2 == 1 { chars.insert(48, at: 0) }
        bytes.reserveCapacity(chars.count / 2)
        var k = 0
        while k < chars.count {
            guard let hi = BigUInt.nibble(chars[k]), let lo = BigUInt.nibble(chars[k + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            k += 2
        }
        self.init(bytes: bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    /// Significant limbs (at least 1).
    var count: Int {
        var n = limbs.count
        while n > 1 && limbs[n - 1] == 0 { n -= 1 }
        return n
    }

    var bitWidth: Int {
        let n = count
        return (n - 1) * 64 + (64 - limbs[n - 1].leadingZeroBitCount)
    }

    func bit(_ k: Int) -> Bool {
        let w = k / 64
        return w < limbs.count && (limbs[w] >> UInt64(k % 64)) & 1 == 1
    }

    /// Minimal big-endian bytes (at least one byte).
    var bytes: [UInt8] {
        let full = bytes(width: count * 8)
        let firstNonZero = full.firstIndex { $0 != 0 } ?? (full.count - 1)
        return Array(full[firstNonZero...])
    }

    /// Big-endian, left-padded with zeros (or truncated to the low bytes) to `width`.
    func bytes(width: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width)
        for k in 0..<width {
            let w = k / 8
            guard w < limbs.count else { break }
            out[width - 1 - k] = UInt8(truncatingIfNeeded: limbs[w] >> (UInt64(k % 8) * 8))
        }
        return out
    }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        let n = max(a.limbs.count, b.limbs.count)
        for k in stride(from: n - 1, through: 0, by: -1) {
            let x = k < a.limbs.count ? a.limbs[k] : 0
            let y = k < b.limbs.count ? b.limbs[k] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func == (a: BigUInt, b: BigUInt) -> Bool { compare(a, b) == 0 }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var out = [UInt64](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for k in 0..<n {
            let x = k < a.limbs.count ? a.limbs[k] : 0
            let y = k < b.limbs.count ? b.limbs[k] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[k] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[n] = carry
        return BigUInt(limbs: out)
    }

    /// a − b; requires a ≥ b.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(compare(a, b) >= 0, "BigUInt underflow")
        var out = a.limbs
        var borrow: UInt64 = 0
        for k in 0..<out.count {
            let y = k < b.limbs.count ? b.limbs[k] : 0
            let (d1, o1) = out[k].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[k] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = a.count, m = b.count
        var out = [UInt64](repeating: 0, count: n + m)
        for i in 0..<n {
            var carry: UInt64 = 0
            let x = a.limbs[i]
            for j in 0..<m {
                let (hi, lo) = mulAdd(x, b.limbs[j], out[i + j], carry)
                out[i + j] = lo
                carry = hi
            }
            out[i + m] = carry
        }
        return BigUInt(limbs: out)
    }

    /// x·y + c1 + c2 as (high, low); never overflows 128 bits.
    @inline(__always)
    static func mulAdd(_ x: UInt64, _ y: UInt64, _ c1: UInt64, _ c2: UInt64) -> (UInt64, UInt64) {
        let (hi, lo) = x.multipliedFullWidth(by: y)
        let (l1, o1) = lo.addingReportingOverflow(c1)
        let (l2, o2) = l1.addingReportingOverflow(c2)
        return (hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0), l2)
    }
}

/// Arithmetic modulo an odd modulus N, in Montgomery form internally (R = 2^(64·n)).
struct Montgomery {
    let n: [UInt64]        // modulus limbs, exactly `size` long
    let size: Int
    let nPrime: UInt64     // −N⁻¹ mod 2^64
    let r2: [UInt64]       // R² mod N

    init(modulus: BigUInt) {
        size = modulus.count
        n = Array(modulus.limbs[0..<size])
        precondition(n[0] & 1 == 1, "Montgomery needs an odd modulus")
        // Newton iteration for N⁻¹ mod 2^64 (each step doubles the correct bits).
        var inv: UInt64 = 1
        for _ in 0..<7 { inv = inv &* (2 &- n[0] &* inv) }
        nPrime = 0 &- inv
        // R² mod N by doubling 1 (2·64·size) times, reducing as we go.
        var x = [UInt64](repeating: 0, count: size)
        x[0] = 1
        let mod = BigUInt(limbs: n)
        for _ in 0..<(2 * 64 * size) {
            var carry: UInt64 = 0
            for k in 0..<size {
                let next = x[k] >> 63
                x[k] = x[k] << 1 | carry
                carry = next
            }
            if carry == 1 || BigUInt.compare(BigUInt(limbs: x), mod) >= 0 {
                var borrow: UInt64 = 0
                for k in 0..<size {
                    let (d1, o1) = x[k].subtractingReportingOverflow(n[k])
                    let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                    x[k] = d2
                    borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
            }
        }
        r2 = x
    }

    /// a·b·R⁻¹ mod N (CIOS). Inputs < N, `size` limbs each.
    func mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: size + 2)
        for i in 0..<size {
            var c: UInt64 = 0
            let bi = b[i]
            for j in 0..<size {
                (c, t[j]) = BigUInt.mulAdd(a[j], bi, t[j], c)
            }
            var (s, o) = t[size].addingReportingOverflow(c)
            t[size] = s
            t[size + 1] = o ? 1 : 0
            let m = t[0] &* nPrime
            (c, _) = BigUInt.mulAdd(m, n[0], t[0], 0)
            for j in 1..<size {
                (c, t[j - 1]) = BigUInt.mulAdd(m, n[j], t[j], c)
            }
            (s, o) = t[size].addingReportingOverflow(c)
            t[size - 1] = s
            t[size] = t[size + 1] &+ (o ? 1 : 0)
        }
        var out = Array(t[0..<size])
        if t[size] != 0 || !lessThanN(out) {
            var borrow: UInt64 = 0
            for k in 0..<size {
                let (d1, o1) = out[k].subtractingReportingOverflow(n[k])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                out[k] = d2
                borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
        }
        return out
    }

    private func lessThanN(_ x: [UInt64]) -> Bool {
        for k in stride(from: size - 1, through: 0, by: -1) where x[k] != n[k] {
            return x[k] < n[k]
        }
        return false
    }

    private func limbs(_ x: BigUInt) -> [UInt64] {
        var v = x
        if BigUInt.compare(v, BigUInt(limbs: n)) >= 0 { v = reduce(v) }
        var out = Array(v.limbs.prefix(size))
        if out.count < size { out += [UInt64](repeating: 0, count: size - out.count) }
        return out
    }

    /// x mod N for any x (schoolbook shift-subtract; only used on small inputs).
    func reduce(_ x: BigUInt) -> BigUInt {
        let mod = BigUInt(limbs: n)
        if BigUInt.compare(x, mod) < 0 { return x }
        var r = BigUInt(0)
        for k in stride(from: x.bitWidth - 1, through: 0, by: -1) {
            r = r + r
            if x.bit(k) { r = r + BigUInt(1) }
            if BigUInt.compare(r, mod) >= 0 { r = r - mod }
        }
        return r
    }

    /// a·b mod N.
    func mulMod(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(limbs: mul(mul(limbs(a), limbs(b)), r2))
    }

    /// base^exp mod N (left-to-right square and multiply).
    func pow(_ base: BigUInt, _ exp: BigUInt) -> BigUInt {
        let b = mul(limbs(base), r2)                  // base in Montgomery form
        var one = [UInt64](repeating: 0, count: size)
        one[0] = 1
        var acc = mul(one, r2)                        // 1 in Montgomery form
        for k in stride(from: exp.bitWidth - 1, through: 0, by: -1) {   // empty for exp = 0
            acc = mul(acc, acc)
            if exp.bit(k) { acc = mul(acc, b) }
        }
        return BigUInt(limbs: mul(acc, one))          // out of Montgomery form
    }
}
