
import Foundation
import Crypto

enum ScryptError: Error {
    case invalidParameters(String)
    case parametersTooLarge(String)
}

enum Scrypt {


    static func cesu8Bytes(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(s.utf16.count * 3)
        for u in s.utf16 {
            if u < 0x80 {
                out.append(UInt8(u))
            } else if u < 0x800 {
                out.append(UInt8(0xC0 | (u >> 6)))
                out.append(UInt8(0x80 | (u & 0x3F)))
            } else {
                out.append(UInt8(0xE0 | (u >> 12)))
                out.append(UInt8(0x80 | ((u >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (u & 0x3F)))
            }
        }
        return out
    }


    static func pbkdf2Sha256C1(password: [UInt8], salt: [UInt8],
                               dkLen: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out = [UInt8]()
        out.reserveCapacity(((dkLen + 31) / 32) * 32)
        var blockIndex: UInt32 = 1
        while out.count < dkLen {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: salt)
            let indexBytes: [UInt8] = [
                UInt8(truncatingIfNeeded: blockIndex >> 24),
                UInt8(truncatingIfNeeded: blockIndex >> 16),
                UInt8(truncatingIfNeeded: blockIndex >> 8),
                UInt8(truncatingIfNeeded: blockIndex),
            ]
            mac.update(data: indexBytes)
            let block = mac.finalize()
            block.withUnsafeBytes { out.append(contentsOf: $0) }
            blockIndex &+= 1
        }
        if out.count > dkLen {
            out.withUnsafeMutableBytes { buf in
                zeroBytes(UnsafeMutableRawBufferPointer(rebasing: buf[dkLen...]))
            }
            out.removeLast(out.count - dkLen)
        }
        return out
    }


    static func salsa20_8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3]
        var x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11]
        var x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]

        @inline(__always) func rotl(_ a: UInt32, _ n: UInt32) -> UInt32 {
            (a << n) | (a >> (32 - n))
        }

        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7);  x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7);   x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7);   x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13);  x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7);   x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13);  x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }

        b[0] = b[0] &+ x0; b[1] = b[1] &+ x1
        b[2] = b[2] &+ x2; b[3] = b[3] &+ x3
        b[4] = b[4] &+ x4; b[5] = b[5] &+ x5
        b[6] = b[6] &+ x6; b[7] = b[7] &+ x7
        b[8] = b[8] &+ x8; b[9] = b[9] &+ x9
        b[10] = b[10] &+ x10; b[11] = b[11] &+ x11
        b[12] = b[12] &+ x12; b[13] = b[13] &+ x13
        b[14] = b[14] &+ x14; b[15] = b[15] &+ x15
    }


    static func blockMixSalsa8(b: UnsafeMutablePointer<UInt32>,
                               y: UnsafeMutablePointer<UInt32>, r: Int) {
        var x = [UInt32](repeating: 0, count: 16)
        x.withUnsafeMutableBufferPointer { xb in
            let xp = xb.baseAddress!
            xp.update(from: b + (2 * r - 1) * 16, count: 16)
            for i in 0..<(2 * r) {
                let bi = b + i * 16
                for k in 0..<16 { xp[k] ^= bi[k] }
                salsa20_8(xp)
                (y + i * 16).update(from: xp, count: 16)
            }
            for i in 0..<r {
                (b + i * 16).update(from: y + (i * 2) * 16, count: 16)
            }
            for i in 0..<r {
                (b + (i + r) * 16).update(from: y + (i * 2 + 1) * 16, count: 16)
            }
            zeroBytes(UnsafeMutableRawBufferPointer(xb))
        }
    }


    static func smix(b: UnsafeMutablePointer<UInt32>, r: Int, n: Int,
                     v: UnsafeMutablePointer<UInt32>,
                     xy: UnsafeMutablePointer<UInt32>) {
        let words = 32 * r
        let x = xy
        let y = xy + words

        x.update(from: b, count: words)
        for i in 0..<n {
            (v + i * words).update(from: x, count: words)
            blockMixSalsa8(b: x, y: y, r: r)
        }
        let integerifyWord = (2 * r - 1) * 16
        for _ in 0..<n {
            let j = Int((UInt64(x[integerifyWord]) |
                         (UInt64(x[integerifyWord + 1]) << 32)) &
                        UInt64(n - 1))
            let vj = v + j * words
            for k in 0..<words { x[k] ^= vj[k] }
            blockMixSalsa8(b: x, y: y, r: r)
        }
        b.update(from: x, count: words)
    }


    static func derive(password: [UInt8], salt: [UInt8],
                       logN: Int, r: Int, p: Int, dkLen: Int) throws -> [UInt8] {
        guard r > 0, p > 0 else {
            throw ScryptError.invalidParameters("r and p must be positive")
        }
        guard logN >= 1, logN <= 30 else {
            throw ScryptError.invalidParameters("logN out of range (1...30)")
        }
        let n = 1 << logN
        let (rp, rpOverflow) = UInt64(r).multipliedReportingOverflow(by: UInt64(p))
        guard !rpOverflow, rp < (1 << 30) else {
            throw ScryptError.parametersTooLarge("r * p >= 2^30")
        }
        guard dkLen >= 0, UInt64(dkLen) <= ((UInt64(1) << 32) - 1) * 32 else {
            throw ScryptError.parametersTooLarge("dkLen")
        }
        guard r <= Int.max / 128 / p, n <= Int.max / 128 / r else {
            throw ScryptError.parametersTooLarge("128*r*N overflows")
        }
        let totalBytes = UInt64(128) * UInt64(r) * UInt64(n)
            + UInt64(128) * UInt64(r) * UInt64(p)
            + UInt64(256) * UInt64(r)
        guard totalBytes <= (UInt64(1) << 33) else {
            throw ScryptError.parametersTooLarge("working set exceeds 8 GiB")
        }

        let bWords = 32 * r * p
        let vWords = 32 * r * n
        let xyWords = 64 * r

        var bBytes = pbkdf2Sha256C1(password: password, salt: salt,
                                    dkLen: 128 * r * p)
        defer {
            bBytes.withUnsafeMutableBytes { zeroBytes($0) }
        }

        let bBuf = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: bWords)
        let vBuf = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: vWords)
        let xyBuf = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: xyWords)
        defer {
            zeroBytes(UnsafeMutableRawBufferPointer(bBuf))
            zeroBytes(UnsafeMutableRawBufferPointer(vBuf))
            zeroBytes(UnsafeMutableRawBufferPointer(xyBuf))
            bBuf.deallocate()
            vBuf.deallocate()
            xyBuf.deallocate()
        }
        bBuf.initialize(repeating: 0)
        vBuf.initialize(repeating: 0)
        xyBuf.initialize(repeating: 0)

        bBytes.withUnsafeBytes { raw in
            for i in 0..<bWords {
                bBuf[i] = UInt32(raw[4 * i])
                    | UInt32(raw[4 * i + 1]) << 8
                    | UInt32(raw[4 * i + 2]) << 16
                    | UInt32(raw[4 * i + 3]) << 24
            }
        }

        for i in 0..<p {
            smix(b: bBuf.baseAddress! + i * 32 * r, r: r, n: n,
                 v: vBuf.baseAddress!, xy: xyBuf.baseAddress!)
        }

        bBytes.withUnsafeMutableBytes { raw in
            for i in 0..<bWords {
                let w = bBuf[i]
                raw[4 * i] = UInt8(truncatingIfNeeded: w)
                raw[4 * i + 1] = UInt8(truncatingIfNeeded: w >> 8)
                raw[4 * i + 2] = UInt8(truncatingIfNeeded: w >> 16)
                raw[4 * i + 3] = UInt8(truncatingIfNeeded: w >> 24)
            }
        }

        return pbkdf2Sha256C1(password: password, salt: bBytes, dkLen: dkLen)
    }


    static func deriveCryptPadLogin(password: String, salt: String) throws -> [UInt8] {
        var pw = cesu8Bytes(password)
        var st = cesu8Bytes(salt)
        defer {
            pw.withUnsafeMutableBytes { zeroBytes($0) }
            st.withUnsafeMutableBytes { zeroBytes($0) }
        }
        return try derive(password: pw, salt: st,
                          logN: 8, r: 1024, p: 1, dkLen: 192)
    }


    @inline(never)
    static func zeroBytes(_ buf: UnsafeMutableRawBufferPointer) {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        #if canImport(Darwin)
        memset_s(base, buf.count, 0, buf.count)
        #else
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<buf.count { p[i] = 0 }
        #endif
    }
}
