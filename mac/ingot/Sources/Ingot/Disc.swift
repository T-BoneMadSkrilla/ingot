import AppKit
import Foundation

/// What the library shows of a disc image: read from its default.xbe (the
/// certificate's title and title ID, the dashboard's title image).
struct DiscInfo: Codable, Hashable {
    var title: String
    var titleID: UInt32
    var region: UInt32
}

enum Disc {
    /// Where the game partition starts in the image kinds in use: an XISO,
    /// and the redump layouts of XGD1, XGD2 and XGD3 discs.
    private static let partitionOffsets: [UInt64] = [0, 0x1830_0000, 0x0FD9_0000, 0x0208_0000]
    private static let sector: UInt64 = 2048

    static func read(_ url: URL) -> (DiscInfo, NSImage?)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        for base in partitionOffsets {
            guard let vd = bytes(fh, base + 32 * sector, 32),
                  String(decoding: vd.prefix(20), as: UTF8.self) == "MICROSOFT*XBOX*MEDIA"
            else { continue }
            let rootSector = u32(vd, 20), rootSize = u32(vd, 24)
            guard let entry = findFile(fh, base, rootSector, rootSize, "default.xbe") else { return nil }
            return xbe(fh, base + UInt64(entry.sector) * sector, entry.size)
        }
        return nil
    }

    // MARK: XDVDFS

    private static func findFile(_ fh: FileHandle, _ base: UInt64, _ dirSector: UInt32, _ dirSize: UInt32,
                                 _ name: String) -> (sector: UInt32, size: UInt32)? {
        guard dirSize > 0, dirSize < 1 << 22,
              let dir = bytes(fh, base + UInt64(dirSector) * sector, Int(dirSize)) else { return nil }
        // Entries form a binary tree by offset (in dwords); walk it all.
        var stack: [Int] = [0], seen = Set<Int>()
        while let off = stack.popLast() {
            guard off + 14 <= dir.count, seen.insert(off).inserted else { continue }
            let left = Int(u16(dir, off)), right = Int(u16(dir, off + 2))
            if left == 0xFFFF { continue }
            let start = u32(dir, off + 4), size = u32(dir, off + 8)
            let len = Int(dir[off + 13])
            guard off + 14 + len <= dir.count else { continue }
            let entryName = String(decoding: dir[(off + 14)..<(off + 14 + len)], as: UTF8.self)
            if entryName.caseInsensitiveCompare(name) == .orderedSame {
                return (start, size)
            }
            if left != 0 { stack.append(left * 4) }
            if right != 0 { stack.append(right * 4) }
        }
        return nil
    }

    // MARK: XBE

    private static func xbe(_ fh: FileHandle, _ at: UInt64, _ size: UInt32) -> (DiscInfo, NSImage?)? {
        guard let head = bytes(fh, at, 0x180), String(decoding: head.prefix(4), as: UTF8.self) == "XBEH" else {
            return nil
        }
        let baseVA = u32(head, 0x104), headerSize = u32(head, 0x108)
        guard headerSize >= 0x180, headerSize < 1 << 20, let hdr = bytes(fh, at, Int(headerSize)) else { return nil }
        let cert = Int(u32(hdr, 0x118) &- baseVA)
        guard cert > 0, cert + 0xA8 <= hdr.count else { return nil }
        let titleID = u32(hdr, cert + 8)
        var units: [UInt16] = []
        for i in 0..<40 {
            let c = u16(hdr, cert + 0xC + i * 2)
            if c == 0 { break }
            units.append(c)
        }
        let title = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        let region = u32(hdr, cert + 0xA0)

        var image: NSImage?
        let nsec = Int(u32(hdr, 0x11C)), secs = Int(u32(hdr, 0x120) &- baseVA)
        for i in 0..<min(nsec, 64) {
            let s = secs + i * 0x38
            guard s + 0x38 <= hdr.count else { break }
            let nameAt = Int(u32(hdr, s + 0x14) &- baseVA)
            guard nameAt >= 0, nameAt + 9 <= hdr.count else { continue }
            if String(decoding: hdr[nameAt..<(nameAt + 9)], as: UTF8.self) == "$$XTIMAGE" {
                let raw = u32(hdr, s + 0xC), rawSize = u32(hdr, s + 0x10)
                if rawSize < 1 << 20, let data = bytes(fh, at + UInt64(raw), Int(rawSize)) {
                    image = XPR.image(data)
                }
                break
            }
        }
        return (DiscInfo(title: title.isEmpty ? "Untitled" : title, titleID: titleID, region: region), image)
    }

    // MARK: bytes

    static func bytes(_ fh: FileHandle, _ at: UInt64, _ n: Int) -> [UInt8]? {
        do {
            try fh.seek(toOffset: at)
            guard let d = try fh.read(upToCount: n), d.count == n else { return nil }
            return [UInt8](d)
        } catch { return nil }
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// The title image: an XPR0 holding one texture, DXT1/3/5 or a swizzled 32-bit
/// one.
enum XPR {
    static func image(_ d: [UInt8]) -> NSImage? {
        guard d.count > 28, String(decoding: d.prefix(4), as: UTF8.self) == "XPR0" else { return nil }
        let headerSize = Int(Disc.u32(d, 8))
        let format = Disc.u32(d, 12 + 12)
        let fmt = (format >> 8) & 0xFF
        let w = 1 << Int((format >> 20) & 0xF), h = 1 << Int((format >> 24) & 0xF)
        guard w <= 1024, h <= 1024, headerSize < d.count else { return nil }
        let px = Array(d[headerSize...])
        var rgba: [UInt8]
        switch fmt {
        case 0x0C: rgba = dxt(px, w, h, kind: 1)
        case 0x0E: rgba = dxt(px, w, h, kind: 3)
        case 0x0F: rgba = dxt(px, w, h, kind: 5)
        case 0x06, 0x07: rgba = argb8Swizzled(px, w, h)
        default: return nil
        }
        guard rgba.count == w * h * 4 else { return nil }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
        guard let rep else { return nil }
        rgba.withUnsafeBufferPointer { src in
            rep.bitmapData?.update(from: src.baseAddress!, count: src.count)
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }

    private static func rgb565(_ c: UInt16) -> (Int, Int, Int) {
        let r = Int(c >> 11) & 31, g = Int(c >> 5) & 63, b = Int(c) & 31
        return (r * 255 / 31, g * 255 / 63, b * 255 / 31)
    }

    private static func dxt(_ s: [UInt8], _ w: Int, _ h: Int, kind: Int) -> [UInt8] {
        let blockBytes = kind == 1 ? 8 : 16
        guard s.count >= (w / 4) * (h / 4) * blockBytes else { return [] }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var o = 0
        for by in 0..<(h / 4) {
            for bx in 0..<(w / 4) {
                var alpha = [UInt8](repeating: 255, count: 16)
                if kind == 3 {
                    for i in 0..<16 {
                        let v = (s[o + i / 2] >> (UInt8(i & 1) * 4)) & 0xF
                        alpha[i] = v * 17
                    }
                } else if kind == 5 {
                    let a0 = Int(s[o]), a1 = Int(s[o + 1])
                    var bits: UInt64 = 0
                    for i in 0..<6 { bits |= UInt64(s[o + 2 + i]) << (8 * UInt64(i)) }
                    for i in 0..<16 {
                        let code = Int((bits >> (3 * UInt64(i))) & 7)
                        let a: Int
                        switch code {
                        case 0: a = a0
                        case 1: a = a1
                        default:
                            if a0 > a1 { a = ((8 - code) * a0 + (code - 1) * a1) / 7 }
                            else if code == 6 { a = 0 }
                            else if code == 7 { a = 255 }
                            else { a = ((6 - code) * a0 + (code - 1) * a1) / 5 }
                        }
                        alpha[i] = UInt8(a)
                    }
                }
                let c = o + (kind == 1 ? 0 : 8)
                let c0 = Disc.u16(s, c), c1 = Disc.u16(s, c + 2)
                let (r0, g0, b0) = rgb565(c0), (r1, g1, b1) = rgb565(c1)
                var pal: [(Int, Int, Int, Int)] = [(r0, g0, b0, 255), (r1, g1, b1, 255)]
                if kind != 1 || c0 > c1 {
                    pal.append(((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3, 255))
                    pal.append(((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3, 255))
                } else {
                    pal.append(((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255))
                    pal.append((0, 0, 0, 0))
                }
                let idx = Disc.u32(s, c + 4)
                for i in 0..<16 {
                    let p = pal[Int((idx >> (2 * UInt32(i))) & 3)]
                    let x = bx * 4 + i % 4, y = by * 4 + i / 4
                    let d = (y * w + x) * 4
                    out[d] = UInt8(p.0); out[d + 1] = UInt8(p.1); out[d + 2] = UInt8(p.2)
                    out[d + 3] = kind == 1 ? UInt8(p.3) : alpha[i]
                }
                o += blockBytes
            }
        }
        return out
    }

    /// NV2A swizzle: x and y bits interleaved, x lowest.
    private static func argb8Swizzled(_ s: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        guard s.count >= w * h * 4 else { return [] }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var off = 0, bit = 0, xs = x, ys = y, mw = w, mh = h
                while mw > 1 || mh > 1 {
                    if mw > 1 { off |= (xs & 1) << bit; bit += 1; xs >>= 1; mw >>= 1 }
                    if mh > 1 { off |= (ys & 1) << bit; bit += 1; ys >>= 1; mh >>= 1 }
                }
                let src = off * 4, dst = (y * w + x) * 4
                out[dst] = s[src + 2]; out[dst + 1] = s[src + 1]; out[dst + 2] = s[src]; out[dst + 3] = s[src + 3]
            }
        }
        return out
    }
}
