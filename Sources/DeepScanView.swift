import SwiftUI
import AppKit

/// Finds files by their content patterns. Works on any drive (formatted, non-APFS, memory
/// cards) but file names and folders are not known; files get numbered names.
@MainActor
final class DeepScanModel: ObservableObject {
    @Published var disks: [Disk] = []
    @Published var selected: Disk?
    @Published var kinds: Set<FileKind> = Set(FileKind.allCases)
    @Published var destination: URL?
    @Published var resultFolder: URL?
    @Published var fixReport = ""
    @Published var fixing = false
    @Published var message: String?
    let job = Job()

    func refresh() {
        Task.detached {
            let d = DiskList.load().filter { !$0.isInternal }
            await MainActor.run {
                self.disks = d + self.disks.filter(\.isImage)
                if self.selected == nil { self.selected = d.first { !$0.detail.contains("Disk Image") } ?? d.first }
            }
        }
    }

    func pickImage() {
        let p = NSOpenPanel()
        p.message = "Choose a disk image (.dmg, .img, .iso, .bin) made from the drive"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        if p.runModal() == .OK, let u = p.url {
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? UInt64) ?? 0
            let d = Disk(id: u.path, name: u.lastPathComponent, size: size, detail: "Disk image file", isImage: true, isInternal: false)
            disks.removeAll { $0.isImage }
            disks.append(d)
            selected = d
        }
    }

    private var resumeKey: String { "deepscan-resume-\(selected?.key ?? "")" }
    var resumePoint: (offset: UInt64, dir: String)? {
        guard let d = UserDefaults.standard.dictionary(forKey: resumeKey),
              let o = d["offset"] as? NSNumber, let dir = d["dir"] as? String,
              FileManager.default.fileExists(atPath: dir) else { return nil }
        return (o.uint64Value, dir)
    }

    func start(resume: Bool = false) {
        guard let disk = selected, !kinds.isEmpty else { return }
        let out: URL
        var offset: UInt64 = 0
        if resume, let r = resumePoint {
            out = URL(fileURLWithPath: r.dir)
            offset = r.offset
        } else {
            guard let dest = destination else { return }
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH-mm"
            out = dest.appendingPathComponent("Revive Deep Scan \(stamp.string(from: Date()))")
        }
        resultFolder = out
        fixReport = ""
        message = nil
        let kindList = kinds.map(\.rawValue).sorted().joined(separator: ",")
        let key = resumeKey
        job.start({ prog in
            [Tool.exe, "--carve", disk.devicePath, out.path, prog, kindList, "\(getuid())", "\(getgid())", "\(offset)"]
        }, device: disk.devicePath, total: disk.size) { p in
            if p.scanned < p.total {
                UserDefaults.standard.set(["offset": NSNumber(value: p.scanned), "dir": out.path], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            if p.error == nil { self.message = p.found == 0 ? "Scan finished. No files were found." : "Done: \(p.found.formatted()) files recovered." }
        }
    }

    func fixVideos() {
        guard let dir = (resultFolder ?? resumePoint.map { URL(fileURLWithPath: $0.dir) })?.path else { return }
        fixing = true
        fixReport = "Rejoining videos with their indexes…"
        Task.detached {
            let out = Tool.run([Tool.exe, "--fix-videos", dir], admin: false)
            await MainActor.run { self.fixReport = out; self.fixing = false }
        }
    }

    func openResult() {
        if let r = resultFolder ?? resumePoint.map({ URL(fileURLWithPath: $0.dir) }) { NSWorkspace.shared.open(r) }
    }
}

struct DeepScanView: View {
    @StateObject private var m = DeepScanModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("Deep Scan", "Search the raw drive for photos, videos, audio, documents and Adobe projects. Use this for formatted drives, memory cards, or when Recover Files finds nothing. Recovered files get numbered names.")
                AccessBanner()
                GroupBox("1. Choose the drive") {
                    VStack(alignment: .leading) {
                        DrivePicker(disks: m.disks, selected: $m.selected, disabled: m.job.running, refresh: m.refresh)
                        Button("Use a Disk Image File…", systemImage: "doc") { m.pickImage() }.disabled(m.job.running)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("2. What to look for") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                        ForEach(FileKind.allCases) { k in
                            Toggle(k.englishTitle, isOn: Binding(get: { m.kinds.contains(k) },
                                                                set: { if $0 { m.kinds.insert(k) } else { m.kinds.remove(k) } }))
                        }
                    }
                    .padding(6)
                }
                .disabled(m.job.running)
                GroupBox("3. Save recovered files to") {
                    DestinationPicker(folder: $m.destination, source: m.selected).padding(6)
                }
                .disabled(m.job.running)

                if let p = m.job.progress {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressSummary(p: p, running: m.job.running)
                            HStack(spacing: 12) {
                                Text("Found: \(p.found)").bold()
                                ForEach(p.byType.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                    Text("\(k) \(v)").foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        }
                        .padding(6)
                    }
                }
                if let msg = m.message ?? m.job.error { Text(msg).foregroundStyle(m.job.error == nil ? .green : .orange) }
                if !m.fixReport.isEmpty {
                    Text(m.fixReport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if m.resultFolder != nil || m.resumePoint != nil {
                        Button("Show Files") { m.openResult() }
                        Button("Repair Broken Videos") { m.fixVideos() }.disabled(m.fixing || m.job.running)
                    }
                    Spacer()
                    if m.job.running {
                        Button("Stop", role: .destructive) { m.job.stop() }
                    } else {
                        if let r = m.resumePoint { Button("Continue from \(formatBytes(r.offset))") { m.start(resume: true) } }
                        Button("Start Deep Scan") { m.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(m.selected == nil || m.destination == nil || m.kinds.isEmpty)
                    }
                }
                .controlSize(.large)
            }
            .padding(.trailing, 8)
        }
        .onAppear { m.refresh() }
    }
}

extension FileKind {
    var englishTitle: String {
        switch self {
        case .project: return "After Effects & Premiere Pro projects"
        case .video: return "Videos & iPhone photos (MP4, MOV, HEIC)"
        case .audio: return "Audio (WAV, AIFF)"
        case .jpg: return "Photos (JPG)"
        case .png: return "Images (PNG)"
        case .gif: return "GIF"
        case .pdf: return "PDF documents"
        case .office: return "Word, Excel, PowerPoint, ZIP"
        }
    }
}
