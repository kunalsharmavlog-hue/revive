import SwiftUI
import AppKit

// MARK: - Drives

struct Disk: Identifiable, Hashable {
    let id: String            // disk4, or a file path for images
    let name: String
    let size: UInt64
    let detail: String
    let isImage: Bool
    let isInternal: Bool
    var devicePath: String { isImage ? id : "/dev/r\(id)" }
    var key: String { "\(name)-\(size)" }
}

enum DiskList {
    static func plist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func load() -> [Disk] {
        guard let list = plist(["list", "-plist"]), let whole = list["WholeDisks"] as? [String] else { return [] }
        return whole.compactMap { id in
            guard let info = plist(["info", "-plist", id]) else { return nil }
            // Skip synthesized APFS containers; they are views onto a physical disk already listed.
            if (info["Content"] as? String)?.hasPrefix("EF57347C-0000-11AA") == true { return nil }
            let name = (info["MediaName"] as? String) ?? id
            let size = (info["TotalSize"] as? UInt64) ?? (info["Size"] as? UInt64) ?? 0
            let internalDisk = (info["Internal"] as? Bool) ?? false
            let ssd = (info["SolidState"] as? Bool) ?? false
            let bus = (info["BusProtocol"] as? String) ?? ""
            let tags = [internalDisk ? "Internal" : "External", ssd ? "SSD" : nil, bus.isEmpty ? nil : bus].compactMap { $0 }
            return Disk(id: id, name: name, size: size, detail: "\(id) · " + tags.joined(separator: " · "),
                        isImage: false, isInternal: internalDisk)
        }
    }

    /// The Apple_APFS partition on a whole disk, e.g. "disk6s2".
    static func apfsPartition(of disk: String) -> String? {
        guard let list = plist(["list", "-plist", disk]),
              let all = list["AllDisksAndPartitions"] as? [[String: Any]],
              let parts = all.first?["Partitions"] as? [[String: Any]] else { return nil }
        return parts.first { ($0["Content"] as? String) == "Apple_APFS" }?["DeviceIdentifier"] as? String
    }

    /// Whole-disk identifier backing a path's volume, e.g. "disk3".
    static func wholeDisk(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard let info = plist(["info", "-plist", from]) else { return nil }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String,
           let storeInfo = plist(["info", "-plist", store]) {
            return storeInfo["ParentWholeDisk"] as? String
        }
        return info["ParentWholeDisk"] as? String
    }
}

func formatBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

// MARK: - Permissions

enum Access {
    /// Raw drives can only be read when this app has Full Disk Access. The TCC database is
    /// readable exactly when that permission is on.
    static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// Where scans of each drive are kept so a drive is only ever scanned once.
enum Store {
    static var root: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Revive")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func indexDir(for disk: Disk) -> URL {
        let safe = disk.key.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent("Scans/\(safe)")
    }
}

// MARK: - Running the engine

enum Tool {
    static var exe: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// Runs a command, as root through the standard macOS password prompt when `admin`.
    nonisolated static func run(_ args: [String], admin: Bool) -> String {
        let p = Process()
        if admin {
            let shell = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " 2>&1"
            let script = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
        } else {
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "Could not start \(args[0])" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if admin && text.contains("-128") { return "ERROR: Cancelled." }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(". . .") && $0.range(of: #"^[0-9a-f]{4}:  "#, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    /// A password is only needed when the drive is not readable as the current user.
    static func needsAdmin(_ device: String) -> Bool { access(device, R_OK) != 0 }
}

/// Runs one long engine job and follows its progress file.
@MainActor
final class Job: ObservableObject {
    @Published var progress: CarveProgress?
    @Published var running = false
    @Published var error: String?

    private var timer: Timer?
    private(set) var progressPath = ""
    private var onFinish: ((CarveProgress) -> Void)?

    func start(_ argsAfterProgress: (String) -> [String], device: String, total: UInt64,
               onFinish: @escaping (CarveProgress) -> Void) {
        progressPath = NSTemporaryDirectory() + "revive-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: progressPath + ".stop")
        self.onFinish = onFinish
        error = nil
        progress = CarveProgress()
        progress?.total = total
        running = true
        let args = argsAfterProgress(progressPath)
        let admin = Tool.needsAdmin(device)
        let path = progressPath
        Task.detached {
            let out = Tool.run(args, admin: admin)
            let wrote = FileManager.default.fileExists(atPath: path)
            await MainActor.run {
                guard self.running else { return }
                if !wrote {
                    self.running = false
                    self.progress = nil
                    self.timer?.invalidate()
                    self.error = out.contains("Cancelled") ? "Cancelled." : "Could not start: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else {
                    self.poll()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard running, let d = FileManager.default.contents(atPath: progressPath),
              let p = try? JSONDecoder().decode(CarveProgress.self, from: d) else { return }
        progress = p
        guard p.done else { return }
        running = false
        timer?.invalidate()
        if let e = p.error {
            error = e.contains("Operation not permitted")
                ? "macOS blocked access to the drive. Give Revive Full Disk Access, quit and reopen Revive, then try again."
                : e
        }
        try? FileManager.default.removeItem(atPath: progressPath)
        onFinish?(p)
    }

    /// Asks the engine to stop at the next safe point.
    func stop() { FileManager.default.createFile(atPath: progressPath + ".stop", contents: Data()) }
}

// MARK: - Shared views

struct AccessBanner: View {
    var body: some View {
        if !Access.hasFullDiskAccess {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access needed").fontWeight(.semibold)
                    Text("Revive needs it to read damaged drives. Turn it on in System Settings, then quit and reopen Revive.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show Revive in Finder") { Access.revealApp() }
                Button("Open Settings") { Access.openSettings() }.buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct DrivePicker: View {
    let disks: [Disk]
    @Binding var selected: Disk?
    var disabled = false
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if disks.isEmpty {
                Text("No drives found. Connect the drive and click Refresh.").foregroundStyle(.secondary)
            }
            ForEach(disks) { d in
                Button { selected = d } label: {
                    HStack {
                        Image(systemName: selected == d ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
                        Image(systemName: d.isInternal ? "internaldrive" : "externaldrive")
                        VStack(alignment: .leading) {
                            Text(d.name).fontWeight(.medium)
                            Text("\(formatBytes(d.size)) · \(d.detail)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh).padding(.top, 2)
        }
        .disabled(disabled)
    }
}

/// Where recovered files go: any mounted drive, Google Drive, or a chosen folder.
struct DestinationPicker: View {
    @Binding var folder: URL?
    var source: Disk?

    private var volumes: [(name: String, url: URL, free: UInt64)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard u.path.hasPrefix("/Volumes/"), let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsReadOnly != true else { return nil }
            return (v.volumeName ?? u.lastPathComponent, u, UInt64(v.volumeAvailableCapacity ?? 0))
        }
    }

    private var googleDrive: URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let accounts = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        return accounts.filter { $0.hasPrefix("GoogleDrive-") }.sorted().first
            .map { cloud.appendingPathComponent($0).appendingPathComponent("My Drive") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folder?.path ?? "No destination chosen").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Folder…") { choose() }
            }
            HStack {
                Text("Quick picks:").font(.caption).foregroundStyle(.secondary)
                ForEach(volumes, id: \.url) { v in
                    Button("\(v.name) (\(formatBytes(v.free)) free)", systemImage: "externaldrive") { folder = v.url }
                        .controlSize(.small)
                }
                if let g = googleDrive {
                    Button("Google Drive", systemImage: "icloud") { folder = g }.controlSize(.small)
                }
                Button("Desktop", systemImage: "desktopcomputer") {
                    folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                }.controlSize(.small)
            }
            Text("Always save to a different drive than the one you are recovering from.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.message = "Choose where recovered files go. Use a different drive than the one you are recovering."
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK { folder = p.url }
    }
}

struct ProgressSummary: View {
    let p: CarveProgress
    let running: Bool

    var body: some View {
        let copying = p.phase == "copy"
        let done = copying ? (p.bytesDone ?? 0) : p.scanned
        let total = copying ? max(p.bytesTotal ?? 1, 1) : max(p.total, 1)
        let frac = min(Double(done) / Double(total), 1)
        let elapsed = Date().timeIntervalSince(p.startedAt)
        let speed = elapsed > 2 ? Double(done) / elapsed : 0
        VStack(alignment: .leading, spacing: 6) {
            Text(copying ? "Copying files" : "Reading drive").font(.callout.weight(.semibold))
            ProgressView(value: frac)
            HStack {
                Text("\(formatBytes(done)) of \(formatBytes(total))  (\(Int(frac * 100))%)")
                Spacer()
                if running, speed > 0, !copying || done > 0 {
                    let eta = Double(total - min(done, total)) / speed
                    Text("\(formatBytes(UInt64(speed)))/s · about \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))) left")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}
