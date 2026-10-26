import SwiftUI
import AppKit

/// Recover files with their real names and folders from a damaged APFS drive:
/// scan once, browse what was found, tick what you want, recover.
@MainActor
final class RecoverModel: ObservableObject {
    enum Stage { case pickDrive, scanning, browse, recovering, finished }

    @Published var disks: [Disk] = []
    @Published var selected: Disk? { didSet { if oldValue != selected { loadSavedScan() } } }
    @Published var stage = Stage.pickDrive
    @Published var tree: CatalogTree?
    @Published var selection = Selection()
    @Published var expanded = Set<Int32>([0])
    @Published var query = ""
    @Published var destination: URL?
    @Published var savedScanDate: Date?
    @Published var report = ""
    @Published var resultFolder: URL?
    @Published var message: String?
    let job = Job()

    func refresh() {
        Task.detached {
            let d = DiskList.load().filter { !$0.isInternal }
            await MainActor.run {
                self.disks = d
                if self.selected == nil || !d.contains(where: { $0.id == self.selected?.id }) {
                    let last = UserDefaults.standard.string(forKey: "lastDrive")
                    self.selected = d.first { $0.key == last } ?? d.first { !$0.detail.contains("Disk Image") } ?? d.first
                }
            }
        }
    }

    private var indexDir: URL? { selected.map(Store.indexDir(for:)) }
    private var catalogFile: URL? { indexDir?.appendingPathComponent("CATALOG.tsv") }
    private var nodesFile: URL? { indexDir?.appendingPathComponent("INDEX.nodes") }

    private func loadSavedScan() {
        tree = nil
        selection.clear()
        savedScanDate = nil
        stage = .pickDrive
        guard let c = catalogFile, let n = nodesFile,
              FileManager.default.fileExists(atPath: c.path), FileManager.default.fileExists(atPath: n.path) else { return }
        savedScanDate = (try? FileManager.default.attributesOfItem(atPath: c.path)[.modificationDate]) as? Date
    }

    func openSavedScan() { loadTree() }

    func scan() {
        guard let disk = selected, let dir = indexDir else { return }
        UserDefaults.standard.set(disk.key, forKey: "lastDrive")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        message = nil
        stage = .scanning
        Task.detached {
            guard let part = disk.isImage ? nil as String? : DiskList.apfsPartition(of: disk.id) else {
                await MainActor.run {
                    self.stage = .pickDrive
                    self.message = "No APFS partition was found on this drive. Try Deep Scan instead."
                }
                return
            }
            await MainActor.run {
                let dev = "/dev/r\(part)"
                self.job.start({ prog in
                    [Tool.exe, "--apfs-folders", dev, dir.path, prog, "\(getuid())", "\(getgid())", "0", "!scanonly"]
                }, device: dev, total: disk.size) { _ in
                    if self.job.error != nil { self.stage = .pickDrive; return }
                    self.savedScanDate = Date()
                    self.loadTree()
                }
            }
        }
    }

    /// Stops reading the drive and uses what was found so far.
    func finishScanNow() { job.stop() }

    private func loadTree() {
        guard let c = catalogFile else { return }
        do {
            tree = try CatalogTree(tsv: c.path)
            selection.clear()
            expanded = [0]
            stage = .browse
        } catch {
            message = "Could not read the scan: \(error.localizedDescription)"
            stage = .pickDrive
        }
    }

    /// Quick picks by file type, across the whole drive.
    enum Category: String, CaseIterable {
        case projects = "AE & Premiere Projects", videos = "Videos", photos = "Photos", audio = "Audio", documents = "Documents"
        var extensions: Set<String> {
            switch self {
            case .projects: return ["aep", "aepx", "prproj", "mogrt", "ffx"]
            case .videos: return ["mp4", "mov", "m4v", "mxf", "avi", "mkv", "webm", "braw", "r3d", "mts"]
            case .photos: return ["jpg", "jpeg", "png", "heic", "tif", "tiff", "psd", "gif", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng"]
            case .audio: return ["wav", "mp3", "aif", "aiff", "m4a", "flac", "aac"]
            case .documents: return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "pages", "numbers", "key", "rtf", "csv"]
            }
        }
    }

    func select(_ c: Category) {
        guard let t = tree else { return }
        let items = (1..<t.nodes.count).filter {
            t.nodes[$0].kind == .file && c.extensions.contains((t.nodes[$0].name as NSString).pathExtension.lowercased())
        }
        selection.add(items.map { Int32($0) }, in: t)
    }

    /// Ticks every search result at once (e.g. all folders named "pulkit").
    func selectSearchResults() {
        guard let t = tree, query.count >= 2 else { return }
        selection.add(t.search(query).filter { t.nodes[Int($0)].kind != .lostData }, in: t)
    }

    func recover() {
        guard let t = tree, let disk = selected, let dest = destination, let nodes = nodesFile else { return }
        let ids = selection.engineIds(in: t)
        guard !ids.files.isEmpty || !ids.unnamed.isEmpty else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        let out = dest.appendingPathComponent("Revive Recovery \(stamp.string(from: Date()))")
        resultFolder = out
        let list = Store.root.appendingPathComponent("selection-\(UUID().uuidString).txt")
        try? ids.files.map(String.init).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let unnamed = ids.unnamed.map { "%\($0)" }
        message = nil
        stage = .recovering
        Task.detached {
            guard let part = DiskList.apfsPartition(of: disk.id) else {
                await MainActor.run { self.stage = .browse; self.message = "The drive is no longer connected." }
                return
            }
            await MainActor.run {
                let dev = "/dev/r\(part)"
                self.job.start({ prog in
                    [Tool.exe, "--apfs-folders", dev, out.path, prog, "\(getuid())", "\(getgid())", "0", "@\(nodes.path)", "+\(list.path)"] + unnamed
                }, device: dev, total: disk.size) { _ in
                    try? FileManager.default.removeItem(at: list)
                    self.report = (try? String(contentsOf: out.appendingPathComponent("REPORT.txt"), encoding: .utf8)) ?? ""
                    self.stage = self.job.error == nil ? .finished : .browse
                }
            }
        }
    }

    func openResult() { if let r = resultFolder { NSWorkspace.shared.open(r) } }
}

struct RecoverView: View {
    @StateObject private var m = RecoverModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Recover Files", "Get files back with their real names and folders from a damaged or unreadable APFS drive (SSD, USB drive). The drive is only read, never changed.")
            AccessBanner()

            switch m.stage {
            case .pickDrive: pickDrive
            case .scanning: scanning
            case .browse: browser
            case .recovering: recovering
            case .finished: finished
            }
            if let msg = m.message ?? m.job.error {
                Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .onAppear { m.refresh() }
    }

    private var pickDrive: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("1. Choose the damaged drive") {
                DrivePicker(disks: m.disks, selected: $m.selected, refresh: m.refresh).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("2. Scan it") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Revive reads the whole drive once to find its file index. This takes about 30–40 minutes per terabyte on a fast cable. The result is saved, so you never have to scan the same drive again.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if let d = m.savedScanDate {
                            Button("Use Saved Scan (\(d.formatted(date: .abbreviated, time: .shortened)))") { m.openSavedScan() }
                                .buttonStyle(.borderedProminent)
                            Button("Scan Again") { m.scan() }
                        } else {
                            Button("Scan Drive") { m.scan() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .disabled(m.selected == nil)
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
    }

    private var scanning: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let p = m.job.progress { ProgressSummary(p: p, running: m.job.running) }
                let nodes = m.job.progress?.byType["index-nodes"] ?? 0
                let items = m.job.progress?.byType["items"] ?? 0
                Text("Found so far: \(items.formatted()) files and folders (\(nodes.formatted()) index pieces)")
                Text("Most drives keep their index near the start. If the numbers above stop growing for a long time, you can finish early and browse what was found.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Finish Scan Now") { m.finishScanNow() }
                }
            }
            .padding(6)
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = m.tree {
                HStack {
                    Text("\(t.fileCount.formatted()) files found · \(formatBytes(t.totalSize))").font(.headline)
                    Spacer()
                    TextField("Search names", text: $m.query).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                HStack(spacing: 6) {
                    Text("Select all:").font(.caption).foregroundStyle(.secondary)
                    ForEach(RecoverModel.Category.allCases, id: \.self) { c in
                        Button(c.rawValue) { m.select(c) }
                    }
                    if m.query.count >= 2 { Button("All Search Results") { m.selectSearchResults() } }
                    Spacer()
                    Button("Clear") { m.selection.clear() }
                    Button("Other Drive") { m.stage = .pickDrive }
                }
                .controlSize(.small)

                TreeList(tree: t, selection: $m.selection, expanded: $m.expanded, query: m.query)
                    .frame(minHeight: 260)
                    .border(Color.secondary.opacity(0.25))

                GroupBox("Save recovered files to") {
                    DestinationPicker(folder: $m.destination, source: m.selected).padding(6)
                }
                let sel = m.selection.totals(in: t)
                HStack {
                    Text("Selected: \(sel.files.formatted()) files · \(formatBytes(sel.size))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Recover Selected") { m.recover() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(sel.files == 0 || m.destination == nil)
                }
            }
        }
    }

    private var recovering: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let p = m.job.progress { ProgressSummary(p: p, running: m.job.running) }
                if let p = m.job.progress, let total = p.filesTotal {
                    Text("\(p.found.formatted()) of \(total.formatted()) files").font(.callout)
                }
                Text("You can stop at any time. Running the same recovery again continues where it left off.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Stop") { m.job.stop() } }
            }
            .padding(6)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recovery finished", systemImage: "checkmark.seal.fill").font(.title3.weight(.semibold)).foregroundStyle(.green)
            ScrollView {
                Text(m.report.isEmpty ? "No report was written." : m.report)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            .border(Color.secondary.opacity(0.25))
            Text("Files marked INCOMPLETE were partly overwritten on the drive and may not open.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Recover More") { m.stage = .browse }
                Spacer()
                Button("Show Recovered Files") { m.openResult() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Expandable folder list with tick boxes. Only expanded folders are drawn, so even
/// drives with hundreds of thousands of files stay responsive.
struct TreeList: View {
    let tree: CatalogTree
    @Binding var selection: Selection
    @Binding var expanded: Set<Int32>
    let query: String

    private struct Row: Identifiable { let id: Int32; let depth: Int; let showPath: Bool }

    private var rows: [Row] {
        if query.count >= 2 { return tree.search(query).map { Row(id: $0, depth: 0, showPath: true) } }
        var out: [Row] = []
        func walk(_ i: Int32, _ depth: Int) {
            for c in tree.nodes[Int(i)].children {
                out.append(Row(id: c, depth: depth, showPath: false))
                if expanded.contains(c) { walk(c, depth + 1) }
            }
        }
        walk(0, 0)
        return out
    }

    var body: some View {
        List(rows) { row in
            let n = tree.nodes[Int(row.id)]
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                if n.kind == .folder && !row.showPath {
                    Button {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    } label: {
                        Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right").frame(width: 12)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Button { selection.toggle(row.id, in: tree) } label: {
                    Image(systemName: selection.isChecked(row.id, in: tree) ? "checkmark.square.fill"
                          : selection.isPartial(row.id, in: tree) ? "minus.square" : "square")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(n.kind == .lostData)
                Image(systemName: icon(n)).foregroundStyle(n.kind == .lostData ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(n.name).foregroundStyle(n.kind == .lostData ? .secondary : .primary).lineLimit(1)
                    if row.showPath {
                        Text(tree.path(row.id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if n.kind == .lostData {
                    Text("data lost").font(.caption).foregroundStyle(.secondary)
                } else if n.kind == .folder {
                    Text("\(n.files) files · \(formatBytes(n.size))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(formatBytes(n.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func icon(_ n: CatalogTree.Node) -> String {
        switch n.kind {
        case .folder: return n.name == "Lost folders" || n.name.hasPrefix("Lost folder #") ? "questionmark.folder" : "folder"
        case .lostData: return "doc.badge.ellipsis"
        case .unnamed: return "doc.questionmark"
        case .file:
            let e = (n.name as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "mxf", "avi"].contains(e) { return "film" }
            if ["wav", "mp3", "aif", "aiff", "m4a"].contains(e) { return "waveform" }
            if ["jpg", "jpeg", "png", "heic", "psd", "tif", "tiff", "gif", "webp"].contains(e) { return "photo" }
            if ["aep", "aepx", "prproj"].contains(e) { return "sparkles.tv" }
            return "doc"
        }
    }
}

func header(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title2.bold())
        Text(subtitle).foregroundStyle(.secondary)
    }
}
