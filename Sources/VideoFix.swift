import Foundation

// Rejoins recovered videos that lost their index ("moov" atom) with a stray index found
// elsewhere on the drive. Cameras write the index after the media data, so on a fragmented
// drive it ends up separate. Works only on files in the scan folder; never touches the drive.

enum VideoFix {
    struct Media { let path: String; let dataStart: UInt64; let dataEnd: UInt64 }

    struct Index {
        let path: String
        let bytes: [UInt8]
        var chunks: [(offset: UInt64, size: UInt64, codec: String)] = []
        var first: UInt64 { chunks.map(\.offset).min() ?? 0 }
        var last: UInt64 { chunks.map { $0.offset + $0.size }.max() ?? 0 }
    }

    /// Arguments: --fix-videos <scanFolder>. Prints a report.
    static func run(_ args: [String]) -> Int32 {
        guard let dir = args.first else { print("usage: --fix-videos scanFolder"); return 2 }
        let fm = FileManager.default
        let indexDir = (dir as NSString).appendingPathComponent("VIDEO INDEX")
        let outDir = (dir as NSString).appendingPathComponent("VIDEOS FIXED")

        var broken: [Media] = []
        for sub in ["MOV", "MP4", "3GP", "M4A"] {
            let d = (dir as NSString).appendingPathComponent(sub)
            for name in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted() {
                let p = (d as NSString).appendingPathComponent(name)
                if let m = mediaWithoutIndex(p) { broken.append(m) }
            }
        }
        var indexes: [Index] = []
        for name in ((try? fm.contentsOfDirectory(atPath: indexDir)) ?? []).sorted() {
            let p = (indexDir as NSString).appendingPathComponent(name)
            if let d = fm.contents(atPath: p), var ix = parseIndex(p, [UInt8](d)), !ix.chunks.isEmpty {
                ix.chunks.sort { $0.offset < $1.offset }
                indexes.append(ix)
            }
        }
        print("Videos without index: \(broken.count)")
        print("Stray indexes found:  \(indexes.count)\n")

        var used = Set<String>()
        var fixed = 0, partial = 0
        for m in broken {
            // The index must describe data that fits exactly inside this file's media block.
            let candidates = indexes.filter { ix in
                !used.contains(ix.path) && ix.first >= m.dataStart && ix.last <= m.dataEnd
                    && ix.first - m.dataStart < (1 << 20) && m.dataEnd - ix.last < (8 << 20)
            }.map { ix in (ix, score(m, ix)) }
            guard let (best, valid) = candidates.max(by: { $0.1 < $1.1 }), valid > 0 else {
                print("✗ \(name(m.path)): no matching index")
                continue
            }
            used.insert(best.path)
            try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let ext = (m.path as NSString).pathExtension
            let tag = valid >= 0.999 ? "" : String(format: "_PARTIAL_%02d", Int(valid * 100))
            let out = (outDir as NSString).appendingPathComponent(
                ((name(m.path) as NSString).deletingPathExtension) + tag + "." + ext)
            do {
                try join(m, best, to: out)
                if valid >= 0.999 { fixed += 1 } else { partial += 1 }
                print(String(format: "✓ %@ + %@ → %@ (%.0f%% of frames check out)", name(m.path), name(best.path), name(out), valid * 100))
            } catch {
                print("✗ \(name(m.path)): \(error.localizedDescription)")
            }
        }
        print("\nFixed fully: \(fixed), fixed partly (glitches after a point): \(partial), unmatched: \(broken.count - fixed - partial)")
        return 0
    }

    static func name(_ p: String) -> String { (p as NSString).lastPathComponent }

    // MARK: Recovered media files

    static func mediaWithoutIndex(_ path: String) -> Media? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var p: UInt64 = 0
        var data: (UInt64, UInt64)?
        while p + 8 <= size {
            try? h.seek(toOffset: p)
            guard let hd = try? h.read(upToCount: 16), hd.count >= 8 else { break }
            let b = [UInt8](hd)
            var len = be(b, 0, 4), hdr: UInt64 = 8
            if len == 1, b.count >= 16 { len = be(b, 8, 8); hdr = 16 }
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if type == "moov" { return nil }
            if type == "mdat" { data = (p + hdr, min(p + len, size)) }
            guard len >= 8 else { break }
            p += len
        }
        guard let (s, e) = data else { return nil }
        return Media(path: path, dataStart: s, dataEnd: e)
    }

    // MARK: Index parsing

    static func be(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        guard o + n <= b.count else { return 0 }
        return b[o..<(o + n)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func parseIndex(_ path: String, _ b: [UInt8]) -> Index? {
        guard b.count > 16, String(decoding: b[4..<8], as: UTF8.self) == "moov" else { return nil }
        var ix = Index(path: path, bytes: b)
        for trak in children(b, 8, Int(be(b, 0, 4))) where trak.type == "trak" {
            guard let stbl = find(b, trak, ["mdia", "minf", "stbl"]) else { continue }
            let boxes = children(b, stbl.body, stbl.end)
            func box(_ t: String) -> (type: String, body: Int, end: Int)? { boxes.first { $0.type == t } }
            guard let stsz = box("stsz"), let stsc = box("stsc") else { continue }
            var codec = ""
            if let stsd = box("stsd"), stsd.body + 16 <= b.count { codec = String(decoding: b[(stsd.body + 12)..<(stsd.body + 16)], as: UTF8.self) }

            var offsets: [UInt64] = []
            if let co = box("stco") {
                let n = Int(be(b, co.body + 4, 4))
                offsets = (0..<n).map { be(b, co.body + 8 + $0 * 4, 4) }
            } else if let co = box("co64") {
                let n = Int(be(b, co.body + 4, 4))
                offsets = (0..<n).map { be(b, co.body + 8 + $0 * 8, 8) }
            }
            let fixedSize = be(b, stsz.body + 4, 4)
            let sampleCount = Int(be(b, stsz.body + 8, 4))
            func sampleSize(_ i: Int) -> UInt64 { fixedSize != 0 ? fixedSize : be(b, stsz.body + 12 + i * 4, 4) }

            let entries = Int(be(b, stsc.body + 4, 4))
            let runs = (0..<entries).map { (first: Int(be(b, stsc.body + 8 + $0 * 12, 4)), per: Int(be(b, stsc.body + 12 + $0 * 12, 4))) }
            var sample = 0
            for (ci, off) in offsets.enumerated() {
                let per = runs.last { $0.first <= ci + 1 }?.per ?? 1
                var size: UInt64 = 0
                for _ in 0..<per where sample < sampleCount { size += sampleSize(sample); sample += 1 }
                ix.chunks.append((off, size, codec))
            }
        }
        return ix
    }

    static func children(_ b: [UInt8], _ start: Int, _ end: Int) -> [(type: String, body: Int, end: Int)] {
        var out: [(String, Int, Int)] = []
        var p = start
        while p + 8 <= min(end, b.count) {
            let len = Int(be(b, p, 4))
            guard len >= 8, p + len <= end else { break }
            out.append((String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self), p + 8, p + len))
            p += len
        }
        return out
    }

    static func find(_ b: [UInt8], _ from: (type: String, body: Int, end: Int), _ path: [String]) -> (type: String, body: Int, end: Int)? {
        var cur = from
        for t in path {
            guard let next = children(b, cur.body, cur.end).first(where: { $0.type == t }) else { return nil }
            cur = next
        }
        return cur
    }

    // MARK: Matching and joining

    /// Fraction of video chunks whose first frame header looks right at the indexed offset.
    static func score(_ m: Media, _ ix: Index) -> Double {
        guard let h = FileHandle(forReadingAtPath: m.path) else { return 0 }
        defer { try? h.close() }
        var checked = 0, good = 0
        for c in ix.chunks {
            try? h.seek(toOffset: c.offset)
            guard let d = try? h.read(upToCount: 8), d.count == 8 else { checked += 1; continue }
            let b = [UInt8](d)
            switch c.codec {
            case "avc1", "avc3", "hvc1", "hev1":
                let nal = be(b, 0, 4)
                checked += 1
                if nal > 0, nal <= c.size { good += 1 }
            case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x":
                checked += 1
                if String(decoding: b[4..<8], as: UTF8.self) == "icpf" { good += 1 }
            default:
                continue
            }
        }
        // Without a codec we can check, trust the exact offset fit.
        return checked == 0 ? 0.5 : Double(good) / Double(checked)
    }

    static func join(_ m: Media, _ ix: Index, to out: String) throws {
        let fm = FileManager.default
        var s = statfs()
        if statfs((out as NSString).deletingLastPathComponent, &s) == 0,
           UInt64(s.f_bavail) * UInt64(s.f_bsize) < m.dataEnd + (5 << 30) {
            throw CarveError.message("Not enough free space")
        }
        guard let src = FileHandle(forReadingAtPath: m.path) else { throw CarveError.message("cannot read") }
        defer { try? src.close() }
        fm.createFile(atPath: out, contents: nil)
        guard let dst = FileHandle(forWritingAtPath: out) else { throw CarveError.message("cannot write") }
        defer { try? dst.close() }
        // Same bytes up to the end of the media data, so the index offsets stay valid.
        var p: UInt64 = 0
        while p < m.dataEnd {
            let n = Int(min(UInt64(8 << 20), m.dataEnd - p))
            try src.seek(toOffset: p)
            guard let d = try src.read(upToCount: n), !d.isEmpty else { break }
            try dst.write(contentsOf: d)
            p += UInt64(d.count)
        }
        try dst.write(contentsOf: Data(ix.bytes))
    }
}
