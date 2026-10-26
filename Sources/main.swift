import Foundation

// The same binary is both the app and the (root) scanning engine.
let cliArgs = CommandLine.arguments
if let i = cliArgs.firstIndex(of: "--carve") {
    exit(CarveRunner.run(Array(cliArgs[(i + 1)...])))
}
if let i = cliArgs.firstIndex(of: "--apfs-folders") {
    exit(ApfsFolders.run(Array(cliArgs[(i + 1)...])))
}
if let i = cliArgs.firstIndex(of: "--apfs-catalog") {
    exit(ApfsFolders.catalog(Array(cliArgs[(i + 1)...])))
}
if let i = cliArgs.firstIndex(of: "--fix-videos") {
    exit(VideoFix.run(Array(cliArgs[(i + 1)...])))
}
if let i = cliArgs.firstIndex(of: "--apfs") {
    exit(ApfsRepair.run(Array(cliArgs[(i + 1)...])))
}
ReviveApp.main()
