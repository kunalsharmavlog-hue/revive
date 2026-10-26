import Foundation
import Compression

// MARK: - Shared types (used by both the app and the carver process)

enum FileKind: String, CaseIterable, Codable, Identifiable {
    case project, video, audio, jpg, png, gif, pdf, office
    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: return "After Effects / Premiere Pro projects"
        case .audio: return "Audio (WAV / AIFF)"
        case .jpg: return "Photos (JPG)"
        case .png: return "Images (PNG)"
        case .gif: return "GIF"
        case .pdf: return "PDF documents"
        case .office: return "Word / Excel / PowerPoint / ZIP"
        case .video: return "Videos & iPhone photos (MP4 / MOV / HEIC)"
        }
    }
}

struct CarveProgress: Codable {
    var scanned: UInt64 = 0
    var total: UInt64 = 0
    var found: Int = 0
    var byType: [String: Int] = [:]
    var done = false
    var error: String?
    var startedAt = Date()
    // Copy phase of a by-name recovery (absent for drive scans).
    var phase: String?
    var filesTotal: Int?
    var bytesDone: UInt64?
    var bytesTotal: UInt64?
}

// MARK: - Block reader (raw devices need aligned reads)

final class BlockReader {
    let fd: Int32
    let size: UInt64
    let blockSize = 1 << 20
    private var cache: [UInt64: [UInt8]] = [:]
    private var order: [UInt64] = []

    init(path: String) throws {
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CarveError.message("Cannot open \(path): \(String(cString: strerror(errno)))") }
        var st = stat()
        fstat(fd, &st)
        if (st.st_mode & S_IFMT) == S_IFCHR || (st.st_mode & S_IFMT) == S_IFBLK {
            var count: UInt64 = 0
            var bsize: UInt32 = 0
            _ = ioctl(fd, 0x40046418 /* DKIOCGETBLOCKSIZE */, &bsize)
            _ = ioctl(fd, 0x40086419 /* DKIOCGETBLOCKCOUNT */, &count)
            size = count * UInt64(bsize)
        } else {
            size = UInt64(st.st_size)
        }
        guard size > 0 else { throw CarveError.message("Source has zero size (is the disk connected?)") }
    }

    deinit { close(fd) }

    func block(_ index: UInt64) -> [UInt8] {
        if let b = cache[index] { return b }
        let start = index * UInt64(blockSize)
        let len = Int(min(UInt64(blockSize), size - start))
        // Raw devices need sector-aligned lengths, so read a full block and trim.
        var buf = [UInt8](repeating: 0, count: blockSize)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, blockSize, off_t(start)) }
        let got = max(0, min(n, len))
        if got < blockSize { buf.removeSubrange(got...) }
        cache[index] = buf
        order.append(index)
        if order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return buf
    }

    func byte(_ pos: UInt64) -> UInt8? {
        guard pos < size else { return nil }
        let b = block(pos / UInt64(blockSize))
        let i = Int(pos % UInt64(blockSize))
        return i < b.count ? b[i] : nil
    }

    func bytes(_ pos: UInt64, _ count: Int) -> [UInt8]? {
        guard pos + UInt64(count) <= size else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var p = pos
        while out.count < count {
            let b = block(p / UInt64(blockSize))
            let i = Int(p % UInt64(blockSize))
            guard i < b.count else { return nil }
            let take = min(count - out.count, b.count - i)
            out.append(contentsOf: b[i..<(i + take)])
            p += UInt64(take)
        }
        return out
    }

    func be16(_ p: UInt64) -> UInt64? { bytes(p, 2).map { UInt64($0[0]) << 8 | UInt64($0[1]) } }
    func be32(_ p: UInt64) -> UInt64? { bytes(p, 4).map { $0.reduce(0) { $0 << 8 | UInt64($1) } } }
    func be64(_ p: UInt64) -> UInt64? { bytes(p, 8).map { $0.reduce(0) { $0 << 8 | UInt64($1) } } }
    func le16(_ p: UInt64) -> UInt64? { bytes(p, 2).map { UInt64($0[1]) << 8 | UInt64($0[0]) } }
    func le32(_ p: UInt64) -> UInt64? { bytes(p, 4).map { $0.reversed().reduce(0) { $0 << 8 | UInt64($1) } } }

    /// Finds `pattern` in [from, from+limit). Returns absolute offset of the match.
    func find(_ pattern: [UInt8], from: UInt64, limit: UInt64) -> UInt64? {
        let end = min(size, from + limit)
        var p = from
        let chunk = 1 << 20
        while p < end {
            let n = Int(min(UInt64(chunk + pattern.count - 1), end - p))
            guard n >= pattern.count, let buf = bytes(p, n) else { return nil }
            if let i = fastFind(buf, pattern) { return p + UInt64(i) }
            p += UInt64(chunk)
        }
        return nil
    }
}

enum CarveError: Error { case message(String) }

/// Byte search via libc memmem; Swift's generic firstRange is far too slow for a whole drive.
func fastFind(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard from < hay.count, !needle.isEmpty else { return nil }
    return hay.withUnsafeBytes { h in
        needle.withUnsafeBytes { n in
            guard let hit = memmem(h.baseAddress! + from, h.count - from, n.baseAddress!, n.count) else { return nil }
            return h.baseAddress!.distance(to: UnsafeRawPointer(hit))
        }
    }
}

// MARK: - Format parsers. Each returns (length, extension) for a file starting at `p`, or nil.

struct Carver {
    let r: BlockReader
    let kinds: Set<FileKind>

    static let maxImage: UInt64 = 80 << 20
    static let maxDoc: UInt64 = 500 << 20
    static let maxVideo: UInt64 = 16 << 30

    func identify(_ h: [UInt8], at p: UInt64) -> (UInt64, String, FileKind)? {
        if kinds.contains(.jpg), h[0] == 0xFF, h[1] == 0xD8, h[2] == 0xFF, h[3] >= 0xC0 {
            if let n = jpeg(p) { return (n, "jpg", .jpg) }
        }
        if kinds.contains(.png), h.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            if let n = png(p) { return (n, "png", .png) }
        }
        if kinds.contains(.gif), h.starts(with: Array("GIF8".utf8)), h[5] == 0x61, h[4] == 0x37 || h[4] == 0x39 {
            if let n = gif(p, header: h) { return (n, "gif", .gif) }
        }
        if kinds.contains(.pdf), h.starts(with: Array("%PDF-".utf8)) {
            if let n = pdf(p) { return (n, "pdf", .pdf) }
        }
        if kinds.contains(.office), h.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            if let (n, ext) = zip(p, header: h) { return (n, ext, .office) }
        }
        if kinds.contains(.video), Array(h[4..<8]) == Array("ftyp".utf8) {
            if let (n, ext) = isoMedia(p, header: h) { return (n, ext, .video) }
        }
        let tag = String(decoding: h[0..<4], as: UTF8.self), sub = String(decoding: h[8..<12], as: UTF8.self)
        if kinds.contains(.project), tag == "RIFX", sub == "Egg!", let n = r.be32(p + 4), n < Self.maxDoc {
            return (n + 8, "aep", .project)
        }
        if kinds.contains(.project), h[0] == 0x1F, h[1] == 0x8B, h[2] == 0x08 {
            if let n = gzip(p, mustContain: "PremiereData") { return (n, "prproj", .project) }
        }
        if kinds.contains(.audio), tag == "RIFF", sub == "WAVE", let n = r.le32(p + 4), n > 36 {
            return (n + 8, "wav", .audio)
        }
        if kinds.contains(.audio), tag == "FORM", sub == "AIFF" || sub == "AIFC", let n = r.be32(p + 4), n > 36 {
            return (n + 8, "aif", .audio)
        }
        return nil
    }

    /// Length of a gzip member (Premiere .prproj is gzipped XML), found by inflating it.
    /// Bails out early unless the decompressed start contains `mustContain`.
    func gzip(_ start: UInt64, mustContain marker: String) -> UInt64? {
        guard let h = r.bytes(start, 10) else { return nil }
        var p = start + 10
        if h[3] & 4 != 0 { guard let xl = r.le16(p) else { return nil }; p += 2 + xl }
        for bit: UInt8 in [8, 16] where h[3] & bit != 0 {
            guard let z = r.find([0], from: p, limit: 4096) else { return nil }
            p = z + 1
        }
        if h[3] & 2 != 0 { p += 2 }

        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(sp) }
        let outCap = 1 << 16
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: outCap)
        defer { out.deallocate() }
        let want = Array(marker.utf8)
        var head = [UInt8]()
        var total: UInt64 = 0
        var q = p
        while q - p < Self.maxDoc, q < r.size {
            let n = Int(min(UInt64(1 << 20), r.size - q))
            guard let chunk = r.bytes(q, n) else { return nil }
            var status = COMPRESSION_STATUS_OK
            var left = 0
            chunk.withUnsafeBufferPointer { cb in
                sp.pointee.src_ptr = cb.baseAddress!
                sp.pointee.src_size = n
                repeat {
                    sp.pointee.dst_ptr = out
                    sp.pointee.dst_size = outCap
                    status = compression_stream_process(sp, 0)
                    let produced = outCap - sp.pointee.dst_size
                    total += UInt64(produced)
                    if head.count < 4096 { head.append(contentsOf: UnsafeBufferPointer(start: out, count: min(produced, 4096 - head.count))) }
                } while status == COMPRESSION_STATUS_OK && sp.pointee.src_size > 0 && head.count < 4096
                left = sp.pointee.src_size
            }
            if status == COMPRESSION_STATUS_ERROR { return nil }
            if head.count >= 4096 || status == COMPRESSION_STATUS_END {
                guard head.firstRange(of: want) != nil else { return nil }
            }
            if status == COMPRESSION_STATUS_END {
                // The decoder reads ahead, so locate the exact end via the trailer's
                // uncompressed-size field (CRC32, then size mod 2^32, little endian).
                let consumedEnd = q + UInt64(n - left)
                let isize = (0..<4).map { UInt8(truncatingIfNeeded: total >> (8 * $0)) }
                guard let at = r.find(isize, from: p + 4, limit: consumedEnd + 8 - p) else { return nil }
                return at + 4 - start
            }
            q += UInt64(n - left)
        }
        return nil
    }

    /// A stray video index ("moov" atom) whose header starts at `h`; returns its length.
    func orphanMoov(_ h: UInt64) -> UInt64? {
        guard let size = r.be32(h), size >= 100, size < (256 << 20), h + size <= r.size else { return nil }
        return size
    }

    func jpeg(_ start: UInt64) -> UInt64? {
        var p = start + 2
        // Walk marker segments until Start Of Scan; this skips EXIF thumbnails.
        while true {
            guard let m = r.bytes(p, 2), m[0] == 0xFF else { return nil }
            if m[1] == 0xFF { p += 1; continue }
            if m[1] == 0xD9 { return p + 2 - start }
            guard let len = r.be16(p + 2), len >= 2 else { return nil }
            p += 2 + len
            if m[1] == 0xDA { break }
            if p - start > Self.maxImage { return nil }
        }
        // Inside entropy-coded data, 0xFF is always followed by 0x00 or a restart marker,
        // so the first real FFD9 is the end (progressive JPEGs have more SOS segments).
        var q = p
        while q - start < Self.maxImage {
            guard let e = r.find([0xFF], from: q, limit: Self.maxImage - (q - start)), let nx = r.byte(e + 1) else { return nil }
            if nx == 0xD9 { return e + 2 - start }
            q = e + 1
        }
        return nil
    }

    func png(_ start: UInt64) -> UInt64? {
        var p = start + 8
        while p - start < Self.maxImage {
            guard let len = r.be32(p), let type = r.bytes(p + 4, 4) else { return nil }
            guard type.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else { return nil }
            p += 12 + len
            if type == Array("IEND".utf8) { return p - start }
        }
        return nil
    }

    func gif(_ start: UInt64, header h: [UInt8]) -> UInt64? {
        // Header + logical screen descriptor, then the optional global color table.
        var p = start + 13
        if h[10] & 0x80 != 0 { p += 3 << (UInt64(h[10] & 0x07) + 1) }
        func skipSubBlocks() -> Bool {
            while p - start < Self.maxImage {
                guard let n = r.byte(p) else { return false }
                p += 1 + UInt64(n)
                if n == 0 { return true }
            }
            return false
        }
        while p - start < Self.maxImage {
            guard let tag = r.byte(p) else { return nil }
            switch tag {
            case 0x3B: return p + 1 - start
            case 0x21: p += 2; guard skipSubBlocks() else { return nil }
            case 0x2C:
                guard let packed = r.byte(p + 9) else { return nil }
                p += 10
                if packed & 0x80 != 0 { p += 3 << (UInt64(packed & 0x07) + 1) }
                p += 1 // LZW minimum code size
                guard skipSubBlocks() else { return nil }
            default: return nil
            }
        }
        return nil
    }

    func pdf(_ start: UInt64) -> UInt64? {
        let eof = Array("%%EOF".utf8)
        guard var e = r.find(eof, from: start + 5, limit: Self.maxDoc) else { return nil }
        // Incrementally saved PDFs contain several %%EOF markers close together.
        while let next = r.find(eof, from: e + 5, limit: 1 << 20) { e = next }
        var end = e + 5
        while let b = r.byte(end), b == 0x0D || b == 0x0A, end - e < 7 { end += 1 }
        return end - start
    }

    func zip(_ start: UInt64, header h: [UInt8]) -> (UInt64, String)? {
        guard let eocd = r.find([0x50, 0x4B, 0x05, 0x06], from: start + 30, limit: Self.maxDoc),
              let commentLen = r.le16(eocd + 20) else { return nil }
        let len = eocd + 22 + commentLen - start
        let peek = r.bytes(start, Int(min(len, 64 << 10))) ?? h
        func has(_ s: String) -> Bool { peek.firstRange(of: Array(s.utf8)) != nil }
        let ext = has("word/") ? "docx" : has("xl/") ? "xlsx" : has("ppt/") ? "pptx"
            : has("mimetypeapplication/epub") ? "epub" : "zip"
        return (len, ext)
    }

    func isoMedia(_ start: UInt64, header h: [UInt8]) -> (UInt64, String)? {
        let brand = String(decoding: h[8..<12], as: UTF8.self)
        let ext: String
        switch brand {
        case "qt  ": ext = "mov"
        case "heic", "heix", "mif1", "msf1", "hevc": ext = "heic"
        case "M4A ", "M4B ": ext = "m4a"
        case "3gp4", "3gp5", "3g2a": ext = "3gp"
        default: ext = "mp4"
        }
        let known: Set<String> = ["ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "meta", "pnot", "udta", "moof", "mfra", "sidx", "pdin", "idat", "iinf", "iloc", "styp", "emsg", "prft"]
        var p = start
        var sawData = false
        while p - start < Self.maxVideo {
            guard var size = r.be32(p), let t = r.bytes(p + 4, 4) else { break }
            let type = String(decoding: t, as: UTF8.self)
            guard known.contains(type) else { break }
            if size == 1 { guard let big = r.be64(p + 8) else { break }; size = big }
            guard size >= 8 else { break }
            if type == "moov" || type == "mdat" || type == "meta" { sawData = true }
            p += size
            if p > r.size { return nil }
        }
        return sawData && p > start + 8 ? (p - start, ext) : nil
    }
}

// MARK: - Scan driver

enum CarveRunner {
    /// Arguments: --carve <source> <outputDir> <progressFile> <kinds,comma> <ownerUID> <ownerGID> [startOffset]
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 6 else { print("usage: --carve source outdir progress kinds uid gid"); return 2 }
        let (source, outDir, progressPath) = (args[0], args[1], args[2])
        let kinds = Set(args[3].split(separator: ",").compactMap { FileKind(rawValue: String($0)) })
        let uid = uid_t(args[4]) ?? getuid(), gid = gid_t(args[5]) ?? getgid()
        let stopPath = progressPath + ".stop"
        var progress = CarveProgress()

        func save() {
            if let d = try? JSONEncoder().encode(progress) {
                try? d.write(to: URL(fileURLWithPath: progressPath), options: .atomic)
                chown(progressPath, uid, gid)
            }
        }

        do {
            let r = try BlockReader(path: source)
            let carver = Carver(r: r, kinds: kinds)
            progress.total = r.size
            let fm = FileManager.default
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            chown(outDir, uid, gid)

            let step: UInt64 = 512
            var pos: UInt64 = args.count > 6 ? (UInt64(args[6]) ?? 0) / step * step : 0
            var lastSave = Date.distantPast
            let blk = UInt64(r.blockSize)
            var moovSearchedBlock = UInt64.max

            func makeDir(_ name: String) throws -> String {
                let dir = (outDir as NSString).appendingPathComponent(name)
                if !fm.fileExists(atPath: dir) {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    chown(dir, uid, gid)
                }
                return dir
            }

            while pos + 16 <= r.size {
                let bi = pos / blk
                let block = r.block(bi)
                let base = bi * blk
                var i = Int(pos - base)
                var jumped = false

                // Video indexes ("moov") of fragmented videos sit at arbitrary byte offsets, so
                // search each block byte-wise once. They are needed to make those videos play.
                if kinds.contains(.video), bi != moovSearchedBlock {
                    moovSearchedBlock = bi
                    var from = 12
                    let mvhd = Array("mvhd".utf8), moov = Array("moov".utf8)
                    while from + 4 <= block.count, let k = fastFind(block, mvhd, from: from) {
                        from = k + 4
                        guard Array(block[(k - 8)..<(k - 4)]) == moov else { continue }
                        let at = base + UInt64(k - 12)
                        guard let len = carver.orphanMoov(at) else { continue }
                        let path = (try makeDir("VIDEO INDEX") as NSString)
                            .appendingPathComponent(String(format: "moov_at_%012llx.moov", at))
                        try write(r, from: at, length: len, to: path)
                        chown(path, uid, gid)
                        progress.byType["index", default: 0] += 1
                    }
                }

                while i + 16 <= block.count {
                    let b0 = block[i]
                    // Cheap first-byte filter before the full check.
                    if b0 == 0xFF || b0 == 0x89 || b0 == 0x47 || b0 == 0x25 || b0 == 0x50 || b0 == 0x52 || b0 == 0x46
                        || b0 == 0x1F || block[i + 4] == 0x66 {
                        let h = Array(block[i..<(i + 16)])
                        let at = base + UInt64(i)
                        if let (len, ext, kind) = carver.identify(h, at: at), len > 64 {
                            // Never fill the destination drive: keep a 5 GB reserve.
                            if freeSpace(outDir) < len + (5 << 30) {
                                throw CarveError.message("Output drive is almost full, scan stopped to protect it. Move the recovered files elsewhere (e.g. Google Drive) and scan again.")
                            }
                            progress.found += 1
                            progress.byType[kind.rawValue, default: 0] += 1
                            let dir = try makeDir(ext.uppercased())
                            let name = String(format: "recovered_%06d_at_%012llx.%@", progress.found, at, ext)
                            let path = (dir as NSString).appendingPathComponent(name)
                            try write(r, from: at, length: len, to: path)
                            chown(path, uid, gid)
                            // Skip past small carved files, staying sector-aligned. Big ones (videos) are
                            // often fragmented, so the range they claim can hold other files: keep scanning.
                            pos = len <= (16 << 20) ? (at + len + step - 1) / step * step : at + step
                            jumped = true
                            break
                        }
                    }
                    i += Int(step)
                }
                if !jumped { pos = base + UInt64(block.count) + (step - UInt64(block.count) % step) % step }
                if block.isEmpty { break }
                progress.scanned = min(pos, r.size)

                if Date().timeIntervalSince(lastSave) > 0.5 {
                    lastSave = Date()
                    save()
                    if fm.fileExists(atPath: stopPath) { try? fm.removeItem(atPath: stopPath); break }
                }
            }
        } catch CarveError.message(let m) {
            progress.error = m
        } catch {
            progress.error = error.localizedDescription
        }
        progress.done = true
        save()
        return progress.error == nil ? 0 : 1
    }

    static func freeSpace(_ path: String) -> UInt64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }

    static func write(_ r: BlockReader, from: UInt64, length: UInt64, to path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: path) else { throw CarveError.message("Cannot write \(path)") }
        defer { try? out.close() }
        var p = from
        let end = from + length
        while p < end {
            let n = Int(min(UInt64(4 << 20), end - p))
            guard let chunk = r.bytes(p, n) else { break }
            try out.write(contentsOf: chunk)
            p += UInt64(n)
        }
    }
}
