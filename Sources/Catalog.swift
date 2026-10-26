import Foundation

/// The folder tree of a scanned drive, read from the CATALOG.tsv the engine writes.
/// Folders whose own record was lost appear as "Lost folder #id"; data whose name was lost
/// appears under "Unnamed files".
final class CatalogTree {
    enum Kind: UInt8 { case folder, file, lostData, unnamed }

    struct Node {
        var name: String
        var parent: Int32
        var children: [Int32] = []
        var kind: Kind
        var size: UInt64 = 0          // folders: total of everything inside
        var files: Int32 = 0          // folders: number of recoverable files inside
        var engineId: UInt64 = 0      // file id (or stream id for unnamed data)
    }

    private(set) var nodes: [Node] = [Node(name: "", parent: -1, kind: .folder)]
    private(set) var fileCount = 0
    private(set) var totalSize: UInt64 = 0

    init(tsv path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var childIndex: [Int32: [String: Int32]] = [:]

        func folder(_ name: String, in parent: Int32) -> Int32 {
            if let i = childIndex[parent]?[name] { return i }
            let i = Int32(nodes.count)
            nodes.append(Node(name: name, parent: parent, kind: .folder))
            nodes[Int(parent)].children.append(i)
            childIndex[parent, default: [:]][name] = i
            return i
        }

        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard c.count == 5, let id = UInt64(c[0]), let size = UInt64(c[3]) else { continue }
            var parts = c[4].split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            if parts.count >= 2, parts[0] == "_LOST" {
                // "_LOST/folder-123/..." → one readable top-level group per lost folder.
                parts = ["Lost folders", "Lost folder #" + parts[1].replacingOccurrences(of: "folder-", with: "")] + parts.dropFirst(2)
            }
            var parent: Int32 = 0
            for p in parts.dropLast() { parent = folder(p, in: parent) }
            let leaf = parts.last!
            switch c[2] {
            case "d":
                let i = folder(leaf, in: parent)
                nodes[Int(i)].engineId = id
            default:
                let kind: Kind = c[2] == "x" ? .lostData : c[2] == "n" ? .unnamed : .file
                let i = Int32(nodes.count)
                nodes.append(Node(name: leaf, parent: parent, kind: kind, size: kind == .lostData ? 0 : size,
                                  files: kind == .lostData ? 0 : 1, engineId: id))
                nodes[Int(parent)].children.append(i)
                if kind != .lostData { fileCount += 1; totalSize += size }
            }
        }

        // Children are always created after their parent, so one reverse pass sums each folder.
        for i in stride(from: nodes.count - 1, through: 1, by: -1) {
            let p = Int(nodes[i].parent)
            nodes[p].size += nodes[i].size
            nodes[p].files += nodes[i].files
        }
        for i in nodes.indices where nodes[i].children.count > 1 {
            // Sort a copy: the comparator reads `nodes`, which must not be mutated meanwhile.
            var kids = nodes[i].children
            kids.sort { a, b in
                let x = nodes[Int(a)], y = nodes[Int(b)]
                if (x.kind == .folder) != (y.kind == .folder) { return x.kind == .folder }
                // Readable folders before the "Lost folders" and "Unnamed files" groups.
                let gx = x.name == "Lost folders" || x.name == "Unnamed files", gy = y.name == "Lost folders" || y.name == "Unnamed files"
                if gx != gy { return gy }
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            }
            nodes[i].children = kids
        }
    }

    func path(_ i: Int32) -> String {
        var parts: [String] = []
        var c = i
        while c > 0 { parts.append(nodes[Int(c)].name); c = nodes[Int(c)].parent }
        return parts.reversed().joined(separator: "/")
    }

    func isAncestor(_ a: Int32, of b: Int32) -> Bool {
        var c = nodes[Int(b)].parent
        while c >= 0 { if c == a { return true }; c = nodes[Int(c)].parent }
        return false
    }

    /// Every recoverable file below (or at) a node.
    func files(under i: Int32, into out: inout [Int32]) {
        let n = nodes[Int(i)]
        if n.kind == .file || n.kind == .unnamed { out.append(i); return }
        for c in n.children { files(under: c, into: &out) }
    }

    func search(_ q: String, limit: Int = 400) -> [Int32] {
        var out: [Int32] = []
        for i in 1..<nodes.count where nodes[i].name.localizedCaseInsensitiveContains(q) {
            out.append(Int32(i))
            if out.count >= limit { break }
        }
        return out
    }
}

/// Which parts of the tree the user ticked. Keeps a minimal set: ticking a folder covers
/// everything inside it.
struct Selection {
    private(set) var picked = Set<Int32>()

    func isChecked(_ i: Int32, in t: CatalogTree) -> Bool {
        var c = i
        while c >= 0 { if picked.contains(c) { return true }; c = t.nodes[Int(c)].parent }
        return false
    }

    func isPartial(_ i: Int32, in t: CatalogTree) -> Bool {
        !isChecked(i, in: t) && picked.contains { t.isAncestor(i, of: $0) }
    }

    mutating func toggle(_ i: Int32, in t: CatalogTree) {
        if picked.contains(i) { picked.remove(i); return }
        // Unticking something inside a ticked folder: tick its siblings along the way instead.
        var c = t.nodes[Int(i)].parent
        var chain: [Int32] = [i]
        while c >= 0, !picked.contains(c) { chain.append(c); c = t.nodes[Int(c)].parent }
        if c >= 0 {
            picked.remove(c)
            var keep = c
            for step in chain.reversed() {
                for s in t.nodes[Int(keep)].children where s != step { picked.insert(s) }
                keep = step
            }
            return
        }
        picked = picked.filter { !t.isAncestor(i, of: $0) }
        picked.insert(i)
    }

    mutating func clear() { picked.removeAll() }

    mutating func add(_ items: [Int32], in t: CatalogTree) {
        for i in items where !isChecked(i, in: t) { picked.insert(i) }
    }

    func totals(in t: CatalogTree) -> (files: Int, size: UInt64) {
        picked.reduce((0, 0)) { r, i in (r.0 + Int(t.nodes[Int(i)].files), r.1 + t.nodes[Int(i)].size) }
    }

    /// Engine selectors: file ids for named files, stream ids for unnamed data.
    func engineIds(in t: CatalogTree) -> (files: [UInt64], unnamed: [UInt64]) {
        var all: [Int32] = []
        for i in picked { t.files(under: i, into: &all) }
        var f: [UInt64] = [], u: [UInt64] = []
        for i in Set(all) {
            let n = t.nodes[Int(i)]
            if n.kind == .unnamed { u.append(n.engineId) } else { f.append(n.engineId) }
        }
        return (f, u)
    }
}
