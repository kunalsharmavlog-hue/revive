import SwiftUI
import AppKit

struct ReviveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Revive") {
            ContentView().frame(minWidth: 940, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

struct ContentView: View {
    enum Section: String, CaseIterable {
        case recover = "Recover Files", deep = "Deep Scan", repair = "Repair Drive", about = "About"
        var icon: String {
            switch self {
            case .recover: return "arrow.counterclockwise.circle"
            case .deep: return "magnifyingglass.circle"
            case .repair: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }
    @AppStorage("section") private var section = Section.recover

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Revive").font(.headline)
                        Text("Data recovery for Mac").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 14)
                ForEach(Section.allCases, id: \.self) { s in
                    Button { section = s } label: {
                        Label(s.rawValue, systemImage: s.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(section == s ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Label(Access.hasFullDiskAccess ? "Full Disk Access on" : "Full Disk Access off",
                      systemImage: Access.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.caption).foregroundStyle(Access.hasFullDiskAccess ? .green : .orange)
            }
            .padding(16)
            .frame(width: 210)
            .background(.regularMaterial)

            Divider()

            Group {
                switch section {
                case .recover: RecoverView()
                case .deep: DeepScanView()
                case .repair: RepairView()
                case .about: AboutView()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

enum Credits {
    static let author = "Kunal"
    static let email = "lutly.video@gmail.com"
    static let repo = "https://github.com/kunalsharmavlog-hue/revive"
}

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Revive").font(.largeTitle.bold())
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .foregroundStyle(.secondary)
                    Text("Created by \(Credits.author)").fontWeight(.medium).padding(.top, 4)
                    HStack(spacing: 14) {
                        Link(destination: URL(string: "mailto:\(Credits.email)")!) { Label(Credits.email, systemImage: "envelope") }
                        Link(destination: URL(string: Credits.repo)!) { Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                    }
                    .font(.callout)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                point("lock.shield", "Read-only by design", "Recover Files and Deep Scan never write to the damaged drive. Only Repair Drive writes, and it asks first and keeps a backup.")
                point("externaldrive.badge.checkmark", "Real names and folders", "For APFS drives Revive rebuilds the folder tree from index pieces left on the drive, even when macOS cannot mount it.")
                point("film", "Built for video work", "Recovers After Effects and Premiere Pro projects and their media, and can rejoin videos whose index was split from their data.")
                point("arrow.triangle.2.circlepath", "Pick up where you left off", "Scans are saved, and recoveries skip files that were already copied.")
            }
            Divider()
            Text("Tips").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("• Stop using the damaged drive until your files are safe. Every write can overwrite lost data.")
                Text("• Save recovered files to a different drive, and use the drive's original USB-C cable: some cables only run at USB 2 speed.")
                Text("• Always eject drives before unplugging them. Unplugging during a write is the most common cause of this kind of damage.")
                Text("• No tool can bring back data a drive has already erased (TRIM) or encrypted volumes without their password.")
            }
            .foregroundStyle(.secondary)
            Divider()
            Text("Revive is free, open-source software (MIT License) by \(Credits.author). Questions, bugs or ideas: \(Credits.email)")
                .font(.callout).foregroundStyle(.secondary)
            Text("Revive is provided as is, without warranty. Recovery is never guaranteed. Always keep backups.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
