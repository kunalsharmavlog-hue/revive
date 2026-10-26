import SwiftUI
import AppKit

/// Checks an APFS drive and, when its main superblock is damaged, restores it from the
/// newest valid copy (with a backup for Undo) followed by Apple's own repair.
@MainActor
final class RepairModel: ObservableObject {
    enum Status { case unknown, damaged, healthy, repaired, failed, noPermission }

    @Published var disks: [Disk] = []
    @Published var selected: Disk? { didSet { if oldValue != selected { status = .unknown; checked = false; log = "" } } }
    @Published var log = ""
    @Published var busy = false
    @Published var status = Status.unknown
    @Published var checked = false
    @Published var confirmRepair = false

    func refresh() {
        Task.detached {
            let d = DiskList.load().filter { !$0.isInternal && DiskList.apfsPartition(of: $0.id) != nil }
            await MainActor.run {
                self.disks = d
                if !d.contains(where: { $0.id == self.selected?.id }) { self.selected = d.first }
            }
        }
    }

    private var backupKey: String { "repair-backup-\(selected?.key ?? "")" }
    var lastBackup: String? { UserDefaults.standard.string(forKey: backupKey) }

    func check() { run("check") }

    func repair() {
        let dir = Store.root.appendingPathComponent("Repair Backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        run("repair", backup: dir.appendingPathComponent("\(selected?.name ?? "drive") \(f.string(from: Date())).bin").path)
    }

    func undo() { if let b = lastBackup { run("undo", backup: b) } }

    private func run(_ mode: String, backup: String = "/dev/null") {
        guard let disk = selected else { return }
        busy = true
        log = mode == "check" ? "Reading the drive (nothing is written)…\n" : "Working, do not disconnect the drive…\n"
        let key = backupKey
        Task.detached {
            guard let part = DiskList.apfsPartition(of: disk.id) else {
                await MainActor.run { self.log = "No APFS partition found on this drive."; self.busy = false }
                return
            }
            let dev = "/dev/r\(part)"
            let needWrite = mode != "check"
            let admin = access(dev, needWrite ? (R_OK | W_OK) : R_OK) != 0
            var out = Tool.run([Tool.exe, "--apfs", mode, dev, backup, "\(getuid())", "\(getgid())"], admin: admin)
            if mode != "check", !out.contains("ERROR:") {
                out += "\n" + Tool.run(["/usr/sbin/diskutil", "mountDisk", disk.id], admin: false)
            }
            let result = out
            await MainActor.run {
                self.log += result
                self.busy = false
                if result.contains("Operation not permitted") {
                    self.status = .noPermission
                    self.checked = false
                } else if mode == "check" {
                    self.checked = true
                    self.status = result.contains("DAMAGED") ? .damaged : result.contains("appears to be OK") ? .healthy : .failed
                } else if mode == "repair" {
                    if result.contains("Backup of first") { UserDefaults.standard.set(backup, forKey: key) }
                    self.status = !result.contains("ERROR:") && result.contains("appears to be OK") ? .repaired : .failed
                } else {
                    self.status = .unknown
                    self.checked = false
                }
            }
        }
    }
}

struct RepairView: View {
    @StateObject private var m = RepairModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Repair Drive", "Check an APFS drive that will not mount. If its main index block is damaged, Revive can restore it from a backup copy on the drive. Recover your files first if they matter: repairs write to the drive.")
            AccessBanner()
            GroupBox("Drive") {
                DrivePicker(disks: m.disks, selected: $m.selected, disabled: m.busy, refresh: m.refresh).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            banner
            GroupBox("Report") {
                ScrollView {
                    Text(m.log.isEmpty ? "Click Check first. It only reads the drive." : m.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160)
            }
            HStack {
                if m.busy { ProgressView().controlSize(.small) }
                Spacer()
                if m.lastBackup != nil { Button("Undo Last Repair") { m.undo() }.disabled(m.busy) }
                Button("Check (Read-Only)") { m.check() }.disabled(m.busy || m.selected == nil)
                Button("Repair") { m.confirmRepair = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy || !m.checked || m.status != .damaged)
            }
            .controlSize(.large)
        }
        .onAppear { m.refresh() }
        .alert("Repair this drive?", isPresented: $m.confirmRepair) {
            Button("Repair", role: .destructive) { m.repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revive saves the first 16 MB of the drive to your Mac, replaces the damaged main superblock with its newest valid copy, then runs Apple's fsck_apfs repair. The superblock change can be undone.")
        }
    }

    @ViewBuilder private var banner: some View {
        let (icon, text, color): (String, String, Color) = switch m.status {
        case .unknown: ("questionmark.circle", "Not checked yet.", .secondary)
        case .damaged: ("exclamationmark.triangle.fill", "The main superblock is damaged and a valid backup copy was found. This can be repaired.", .orange)
        case .healthy: ("checkmark.seal.fill", "The superblock is fine. If the drive still will not open, use Recover Files.", .green)
        case .repaired: ("checkmark.circle.fill", "Repaired. If the drive does not appear in Finder, unplug it and plug it back in.", .green)
        case .failed: ("xmark.octagon.fill", "This drive cannot be repaired this way. Use Recover Files to get your data back.", .red)
        case .noPermission: ("lock.fill", "macOS blocked access. Give Revive Full Disk Access, then quit and reopen it.", .orange)
        }
        Label(text, systemImage: icon).foregroundStyle(color).font(.callout.weight(.medium))
    }
}
