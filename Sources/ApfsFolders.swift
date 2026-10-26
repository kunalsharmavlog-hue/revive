import Foundation

// Recovers files WITH their real names and folders from an APFS drive whose container is too
// damaged to mount. APFS keeps file-system metadata in B-tree nodes (directory entries, inodes,
// and the list of disk blocks each file occupies). Even when no checkpoint is valid, those nodes
// still sit on the drive with valid checksums, so we scan for them, rebuild the folder tree and
// copy the chosen files block by block. Read-only on the source drive.

enum ApfsFolders {
    struct Inode {
        var parent: UInt64; var name: String; var isDir: Bool; var stream: UInt64; var size: UInt64; var compressed: Bool; var xid: UInt64
        var nameOnly = false   // only a directory entry survived, not the item's own record
    }
    struct Extent { var length: UInt64; var block: UInt64; var xid: UInt64 }

    static let blockSize = 4096

    struct Catalog {
        var inodes: [UInt64: Inode] = [:]
        var dirNames: [UInt64: (parent: UInt64, name: String, xid: UInt64)] = [:]
        var extents: [UInt64: [UInt64: Extent]] = [:]   // stream id -> logical offset -> extent
        var nodes = 0

        mutating func add(_ node: [UInt8]) {
            nodes += 1
            parseLeaf(node, &inodes, &dirNames, &extents)
        }

        /// Fill in folders known only from directory entries.
        mutating func finish() {
            for (id, d) in dirNames where inodes[id] == nil {
                inodes[id] = Inode(parent: d.parent, name: d.name, isDir: true, stream: id, size: 0, compressed: false, xid: d.xid, nameOnly: true)
            }
        }

        /// Path below the volume root plus every ancestor id. When the chain breaks because a
        /// folder's own record was lost, the rest lives under "_LOST/folder-<missing id>".
        func path(_ id: UInt64) -> (parts: [String], ancestors: Set<UInt64>) {
            var parts: [String] = [], ancestors = Set<UInt64>()
            var cur = id
            while cur > 2, !ancestors.contains(cur) {
                ancestors.insert(cur)
                guard let n = inodes[cur] else {
                    parts += ["folder-\(cur)", "_LOST"]
                    break
                }
                parts.append(n.name.isEmpty ? "unnamed-\(cur)" : n.name.replacingOccurrences(of: "/", with: ":"))
                cur = n.parent
            }
            return (parts.reversed(), ancestors)
        }

        /// One line per item: d = folder, f = file, x = file whose data was lost (only its name
        /// survived), n = data whose name was lost (listed under "Unnamed files").
        func writeTSV(_ file: String) throws {
            var lines = ["id\tparent\ttype\tsize\tpath"]
            let parents = Set(inodes.values.map(\.parent))
            for (id, n) in inodes.sorted(by: { $0.key < $1.key }) {
                var type = n.isDir ? "d" : "f"
                if n.nameOnly, !parents.contains(id), !(n.name as NSString).pathExtension.isEmpty { type = "x" }
                lines.append("\(id)\t\(n.parent)\t\(type)\t\(n.size)\t\(path(id).parts.joined(separator: "/"))")
            }
            let known = Set(inodes.values.map(\.stream))
            for (sid, ext) in extents.sorted(by: { $0.key < $1.key }) where !known.contains(sid) {
                let size = ext.map { $0.key + $0.value.length }.max() ?? 0
                if size >= 64 << 10 { lines.append("\(sid)\t0\tn\t\(size)\tUnnamed files/file-\(sid)") }
            }
            try lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    static func loadNodes(_ file: String, into cat: inout Catalog) throws {
        guard let h = FileHandle(forReadingAtPath: file) else { throw CarveError.message("cannot read \(file)") }
        defer { try? h.close() }
        while let d = try h.read(upToCount: blockSize * 256), !d.isEmpty {
            let b = [UInt8](d)
            var i = 0
            while i + blockSize <= b.count { cat.add(Array(b[i..<(i + blockSize)])); i += blockSize }
        }
    }

    /// Arguments: --apfs-catalog <INDEX.nodes> <out.tsv>. Lists everything found, no drive access.
    static func catalog(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { print("usage: --apfs-catalog INDEX.nodes out.tsv"); return 2 }
        var cat = Catalog()
        do {
            try loadNodes(args[0], into: &cat)
            cat.finish()
            try cat.writeTSV(args[1])
            print("nodes \(cat.nodes), items \(cat.inodes.count)")
            return 0
        } catch { print("ERROR: \(error)"); return 1 }
    }

    /// Arguments: --apfs-folders <apfsPartitionDevice> <outDir> <progressFile> <uid> <gid> <projects 0|1> <selector>...
    /// A selector is a folder name, "#<id>" for a folder by id (also lost ones), or
    /// "@<INDEX.nodes>" to reuse a saved index instead of scanning the whole drive again.
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 6 else { print("usage: --apfs-folders device outdir progress uid gid projects names..."); return 2 }
        let (device, outDir, progressPath) = (args[0], args[1], args[2])
        let uid = uid_t(args[3]) ?? getuid(), gid = gid_t(args[4]) ?? getgid()
        let wantProjects = args[5] == "1"
        let tokens = args.dropFirst(6).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let savedIndex = tokens.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
        let wantedIds = Set(tokens.filter { $0.hasPrefix("#") }.compactMap { UInt64($0.dropFirst()) })
        // "%<id>": a file whose name record was lost but whose block list survived.
        let wantedStreams = tokens.filter { $0.hasPrefix("%") }.compactMap { UInt64($0.dropFirst()) }
        // "+<file>": a list of file ids (one per line), as chosen in the app's file browser.
        var wantedFiles = Set<UInt64>()
        for t in tokens where t.hasPrefix("+") {
            let list = (try? String(contentsOfFile: String(t.dropFirst()), encoding: .utf8)) ?? ""
            for line in list.split(separator: "\n") { if let v = UInt64(line.trimmingCharacters(in: .whitespaces)) { wantedFiles.insert(v) } }
        }
        let scanOnly = tokens.contains("!scanonly")
        let wanted = Set(tokens.filter { !"#@%+!".contains($0.first!) }.map { $0.lowercased() })
        let stopPath = progressPath + ".stop"
        var progress = CarveProgress()
        var lastSave = Date.distantPast
        func save(_ force: Bool = false) {
            guard force || Date().timeIntervalSince(lastSave) > 0.5 else { return }
            lastSave = Date()
            if let d = try? JSONEncoder().encode(progress) {
                try? d.write(to: URL(fileURLWithPath: progressPath), options: .atomic)
                chown(progressPath, uid, gid)
            }
        }

        do {
            let r = try BlockReader(path: device)
            progress.total = r.size
            var cat = Catalog()
            try makeDirs(outDir, root: outDir, uid: uid, gid: gid)

            if let savedIndex {
                // Reuse the index saved by an earlier run: no 30-minute drive scan.
                try loadNodes(savedIndex, into: &cat)
                progress.scanned = r.size
            } else {
                // Phase 1: read the whole drive and collect every valid file-system leaf node,
                // keeping a copy so later runs (and the catalog) need no rescan.
                let nodesPath = (outDir as NSString).appendingPathComponent("INDEX.nodes")
                FileManager.default.createFile(atPath: nodesPath, contents: nil)
                chown(nodesPath, uid, gid)
                let nodesOut = FileHandle(forWritingAtPath: nodesPath)
                defer { try? nodesOut?.close() }
                var pos: UInt64 = 0
                let blk = UInt64(r.blockSize)
                scan: while pos < r.size {
                    let block = r.block(pos / blk)
                    if block.isEmpty { break }
                    var i = 0
                    while i + blockSize <= block.count {
                        // o_type (low 16 bits) = B-tree root/node, o_subtype = FS tree, leaf level.
                        if (block[i + 24] == 2 || block[i + 24] == 3), block[i + 25] == 0, block[i + 28] == 0x0E,
                           block[i + 29] == 0, block[i + 30] == 0, block[i + 31] == 0, block[i + 34] == 0, block[i + 35] == 0 {
                            let node = Array(block[i..<(i + blockSize)])
                            if ApfsRepair.fletcher64(node, count: blockSize) == le(node, 0, 8) {
                                cat.add(node)
                                try nodesOut?.write(contentsOf: node)
                            }
                        }
                        i += blockSize
                    }
                    pos += UInt64(block.count)
                    progress.scanned = min(pos, r.size)
                    progress.byType["index-nodes"] = cat.nodes
                    progress.byType["items"] = cat.inodes.count
                    save()
                    if FileManager.default.fileExists(atPath: stopPath) { try? FileManager.default.removeItem(atPath: stopPath); break scan }
                }
            }
            cat.finish()
            progress.byType["index-nodes"] = cat.nodes
            progress.byType["items"] = cat.inodes.count
            if savedIndex == nil {   // a recovery from a saved scan already has its catalog
                let tsv = (outDir as NSString).appendingPathComponent("CATALOG.tsv")
                try cat.writeTSV(tsv)
                chown(tsv, uid, gid)
            }

            if scanOnly {
                progress.done = true
                save(true)
                return 0
            }

            // Phase 2: choose files and copy them out with their folder paths.
            var chosen: [(id: UInt64, node: Inode, rel: String, project: Bool)] = []
            for (id, n) in cat.inodes.sorted(by: { $0.key < $1.key }) where !n.isDir {
                let (parts, ancestors) = cat.path(id)
                guard !parts.isEmpty else { continue }
                let lower = parts.map { $0.lowercased() }
                let ext = (n.name as NSString).pathExtension.lowercased()
                let inFolder = wantedFiles.contains(id) || lower.dropLast().contains { wanted.contains($0) }
                    || !ancestors.subtracting([id]).isDisjoint(with: wantedIds)
                let isProject = wantProjects && ["aep", "aepx", "prproj"].contains(ext)
                guard inFolder || isProject else { continue }
                var out = parts
                if out.count >= 2, out[0] == "_LOST" {   // same names the app shows
                    out = ["Lost folders", "Lost folder #" + out[1].replacingOccurrences(of: "folder-", with: "")] + out.dropFirst(2)
                }
                chosen.append((id, n, out.joined(separator: "/"), isProject && !inFolder))
            }
            progress.phase = "copy"
            progress.filesTotal = chosen.count + wantedStreams.count
            progress.bytesTotal = chosen.reduce(0) { $0 + $1.node.size }
                + wantedStreams.reduce(0) { t, s in t + (cat.extents[s]?.map { $0.key + $0.value.length }.max() ?? 0) }
            progress.bytesDone = 0
            save(true)

            var report = ["Revive recovery report", "Index nodes found: \(cat.nodes), items: \(cat.inodes.count)", ""]
            var copied = 0, skipped = 0, existing = 0, bytes: UInt64 = 0
            for c in chosen {
                let n = c.node
                if n.compressed { skipped += 1; report.append("SKIPPED (compressed by macOS): \(c.rel)"); continue }
                let dest = (outDir as NSString).appendingPathComponent(c.rel)
                defer { progress.bytesDone = (progress.bytesDone ?? 0) + n.size; save() }
                // Resume: a file already copied in full by an earlier run is left alone.
                if let a = try? FileManager.default.attributesOfItem(atPath: dest), (a[.size] as? UInt64) == n.size {
                    existing += 1
                    progress.found = copied + existing
                    continue
                }
                do {
                    try makeDirs((dest as NSString).deletingLastPathComponent, root: outDir, uid: uid, gid: gid)
                    if CarveRunner.freeSpace(outDir) < n.size + (5 << 30) { throw CarveError.message("The destination drive is almost full.") }
                    let ok = try copyFile(r, cat.extents[n.stream] ?? [:], size: n.size, to: dest)
                    chown(dest, uid, gid)
                    copied += 1
                    bytes += n.size
                    progress.found = copied + existing
                    progress.byType[c.project ? "projects" : "folder-files", default: 0] += 1
                    if !ok {
                        progress.byType["incomplete", default: 0] += 1
                        report.append("INCOMPLETE (some blocks missing): \(c.rel)")
                    }
                } catch CarveError.message(let m) where m.contains("almost full") {
                    throw CarveError.message(m)
                } catch {
                    skipped += 1
                    report.append("FAILED: \(c.rel): \(error.localizedDescription)")
                }
                if FileManager.default.fileExists(atPath: stopPath) {
                    try? FileManager.default.removeItem(atPath: stopPath)
                    report.append("Stopped by user. Run the same recovery again to continue where it left off.")
                    break
                }
            }
            if existing > 0 { report.insert("Already present from an earlier run (kept): \(existing)", at: 2) }
            for sid in wantedStreams {
                guard let ext = cat.extents[sid], !ext.isEmpty else { report.append("NOT FOUND: stream \(sid)"); continue }
                let size = ext.map { $0.key + $0.value.length }.max() ?? 0
                // Name it by content: cameras write MP4/MOV with an "ftyp" box at the start.
                var suffix = "bin"
                if let first = ext[0], first.block != 0, let head = r.bytes(first.block * UInt64(blockSize), 12),
                   String(decoding: head[4..<8], as: UTF8.self) == "ftyp" {
                    suffix = String(decoding: head[8..<12], as: UTF8.self) == "qt  " ? "mov" : "mp4"
                }
                let dest = (outDir as NSString).appendingPathComponent("Unnamed files/file-\(sid).\(suffix)")
                try makeDirs((dest as NSString).deletingLastPathComponent, root: outDir, uid: uid, gid: gid)
                let ok = try copyFile(r, ext, size: size, to: dest)
                if suffix != "bin" { trimToAtoms(dest) }   // the real size was lost with the name
                chown(dest, uid, gid)
                copied += 1
                bytes += size
                progress.bytesDone = (progress.bytesDone ?? 0) + size
                progress.found = copied + existing
                report.append("\(ok ? "UNNAMED" : "UNNAMED, INCOMPLETE"): Unnamed files/file-\(sid).\(suffix) (\(size) bytes)")
                save()
            }
            report.insert("Copied \(copied) files (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))), skipped \(skipped)", at: 2)
            try makeDirs(outDir, root: outDir, uid: uid, gid: gid)
            let rp = (outDir as NSString).appendingPathComponent("REPORT.txt")
            try report.joined(separator: "\n").write(toFile: rp, atomically: true, encoding: .utf8)
            chown(rp, uid, gid)
        } catch CarveError.message(let m) {
            progress.error = m
        } catch {
            progress.error = error.localizedDescription
        }
        progress.done = true
        save(true)
        return progress.error == nil ? 0 : 1
    }

    static func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        guard o >= 0, o + n <= b.count else { return 0 }
        var v: UInt64 = 0
        for k in (0..<n).reversed() { v = v << 8 | UInt64(b[o + k]) }
        return v
    }

    /// Reads the records of one B-tree leaf node of a file-system tree.
    static func parseLeaf(_ b: [UInt8], _ inodes: inout [UInt64: Inode], _ dirNames: inout [UInt64: (parent: UInt64, name: String, xid: UInt64)],
                          _ extents: inout [UInt64: [UInt64: Extent]]) {
        let xid = le(b, 16, 8)
        let flags = le(b, 32, 2)
        guard flags & 2 != 0, flags & 4 == 0 else { return }   // leaf with variable-size entries
        let nkeys = Int(le(b, 36, 4))
        let tocOff = Int(le(b, 40, 2)), tocLen = Int(le(b, 42, 2))
        let keyStart = 56 + tocOff + tocLen
        let valEnd = blockSize - (flags & 1 != 0 ? 40 : 0)
        guard nkeys > 0, nkeys * 8 <= tocLen, keyStart < blockSize else { return }

        for e in 0..<nkeys {
            let t = 56 + tocOff + e * 8
            let ko = keyStart + Int(le(b, t, 2)), kl = Int(le(b, t + 2, 2))
            let vo = valEnd - Int(le(b, t + 4, 2)), vl = Int(le(b, t + 6, 2))
            guard kl >= 8, ko + kl <= blockSize, vo >= keyStart, vo + vl <= valEnd else { continue }
            let hdr = le(b, ko, 8)
            let oid = hdr & 0x0FFF_FFFF_FFFF_FFFF
            let type = hdr >> 60
            switch type {
            case 3 where vl >= 92:   // inode
                if let old = inodes[oid], old.xid > xid { continue }
                let parent = le(b, vo, 8), stream = le(b, vo + 8, 8)
                let bsdFlags = le(b, vo + 68, 4)
                let mode = le(b, vo + 80, 2)
                var name = "", size: UInt64 = 0
                // Extended fields: name and data stream (file size).
                let xf = vo + 92
                if vl > 96 {
                    let n = Int(le(b, xf, 2))
                    var data = xf + 4 + n * 4
                    for f in 0..<n {
                        let ft = b[xf + 4 + f * 4], fs = Int(le(b, xf + 4 + f * 4 + 2, 2))
                        guard data + fs <= vo + vl else { break }
                        if ft == 4 { name = String(decoding: b[data..<(data + max(0, fs - 1))], as: UTF8.self) }
                        if ft == 8, fs >= 8 { size = le(b, data, 8) }
                        data += (fs + 7) / 8 * 8
                    }
                }
                inodes[oid] = Inode(parent: parent, name: name, isDir: mode & 0xF000 == 0x4000, stream: stream,
                                    size: size, compressed: bsdFlags & 0x20 != 0, xid: xid)
            case 9 where vl >= 18:   // directory entry
                let child = le(b, vo, 8)
                var name = ""
                let hashedLen = Int(le(b, ko + 8, 4) & 0x3FF)
                if 12 + hashedLen == kl { name = String(decoding: b[(ko + 12)..<(ko + 12 + max(0, hashedLen - 1))], as: UTF8.self) }
                else {
                    let l = Int(le(b, ko + 8, 2))
                    if 10 + l == kl { name = String(decoding: b[(ko + 10)..<(ko + 10 + max(0, l - 1))], as: UTF8.self) }
                }
                if !name.isEmpty, (dirNames[child]?.xid ?? 0) <= xid { dirNames[child] = (oid, name, xid) }
            case 8 where kl >= 16 && vl >= 16:   // file extent
                let logical = le(b, ko + 8, 8)
                let length = le(b, vo, 8) & 0x00FF_FFFF_FFFF_FFFF
                let phys = le(b, vo + 8, 8)
                if let old = extents[oid]?[logical], old.xid > xid { continue }
                extents[oid, default: [:]][logical] = Extent(length: length, block: phys, xid: xid)
            default:
                continue
            }
        }
    }

    /// Cuts an MP4/MOV to the end of its last top-level box, dropping block padding.
    static func trimToAtoms(_ path: String) {
        guard let h = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var p: UInt64 = 0
        while p + 8 <= size {
            try? h.seek(toOffset: p)
            guard let d = try? h.read(upToCount: 16), d.count >= 8 else { break }
            let b = [UInt8](d)
            var len = b[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if len == 1, b.count >= 16 { len = b[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            guard len >= 8, p + len <= size, b[4...7].allSatisfy({ (0x20...0x7E).contains($0) }) else { break }
            p += len
        }
        if p > 8, p < size { try? h.truncate(atOffset: p) }
    }

    static func makeDirs(_ dir: String, root: String, uid: uid_t, gid: gid_t) throws {
        let fm = FileManager.default
        var missing: [String] = []
        var cur = dir
        while !fm.fileExists(atPath: cur), cur.count > 1 { missing.append(cur); cur = (cur as NSString).deletingLastPathComponent }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for m in missing { chown(m, uid, gid) }
    }

    /// Copies a file's blocks in logical order. Returns false if parts of it were not found.
    static func copyFile(_ r: BlockReader, _ ext: [UInt64: Extent], size: UInt64, to path: String) throws -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: path) else { throw CarveError.message("cannot write") }
        defer { try? out.close() }
        var complete = true
        var written: UInt64 = 0
        for (logical, e) in ext.sorted(by: { $0.key < $1.key }) where logical < size {
            if logical > written {   // gap: unknown data
                try out.write(contentsOf: Data(count: Int(logical - written)))
                written = logical
                complete = false
            }
            guard logical == written else { continue }
            let want = min(e.length, size - logical)
            var done: UInt64 = 0
            while done < want {
                let n = Int(min(UInt64(4 << 20), want - done))
                let chunk: [UInt8]
                if e.block == 0 { chunk = [UInt8](repeating: 0, count: n) }   // sparse hole
                else {
                    guard let c = r.bytes(e.block * UInt64(blockSize) + done, n) else { complete = false; break }
                    chunk = c
                }
                try out.write(contentsOf: chunk)
                done += UInt64(n)
            }
            written += done
        }
        if written < size {
            try out.write(contentsOf: Data(count: Int(size - written)))
            complete = false
        }
        return complete
    }
}
