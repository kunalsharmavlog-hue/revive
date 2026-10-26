import Foundation

// APFS container repair: when the main container superblock (block 0) is damaged the whole
// drive looks empty, but APFS keeps older copies in its checkpoint area. We find the newest
// copy with a valid checksum and put it back at block 0, after saving a backup for Undo.

enum ApfsRepair {
    static let scanBlocks = 4096          // checkpoint descriptor area lives near the start
    static let backupBytes = 16 << 20     // what we save before writing anything

    struct Superblock {
        let block: UInt64
        let xid: UInt64
        let blockSize: Int
        let blockCount: UInt64
        let data: [UInt8]
    }

    /// Arguments: --apfs <check|repair|undo> <device> <backupFile> <uid> <gid>. Prints a log.
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 3 else { print("usage: --apfs check|repair|undo device backupFile [uid gid]"); return 2 }
        let (mode, device, backup) = (args[0], args[1], args[2])
        let uid = args.count > 3 ? uid_t(args[3]) ?? getuid() : getuid()
        let gid = args.count > 4 ? gid_t(args[4]) ?? getgid() : getgid()
        do {
            switch mode {
            case "check": try check(device)
            case "repair": try repair(device, backup: backup, uid: uid, gid: gid)
            case "undo": try undo(device, backup: backup)
            default: print("Unknown mode \(mode)"); return 2
            }
            return 0
        } catch CarveError.message(let m) {
            print("ERROR: \(m)")
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
        return 1
    }

    // MARK: Steps

    static func check(_ device: String) throws {
        let fd = try openDevice(device, write: false)
        defer { close(fd) }
        let (main, copies) = try survey(fd)
        report(main: main, copies: copies)
        print("\n--- Apple fsck_apfs (read-only) ---")
        print(shell("/sbin/fsck_apfs", ["-n", device]))
    }

    static func repair(_ device: String, backup: String, uid: uid_t, gid: gid_t) throws {
        let fd = try openDevice(device, write: true)
        defer { close(fd) }
        let (main, copies) = try survey(fd)
        report(main: main, copies: copies)
        guard let best = copies.first else {
            throw CarveError.message("No valid backup superblock found. This drive can't be repaired this way; use Recover Files instead.")
        }
        if let main, main.xid >= best.xid {
            print("\nMain superblock is valid and up to date, nothing to restore.")
        } else {
            // Save the start of the drive so the change can be undone exactly.
            var saved = [UInt8](repeating: 0, count: backupBytes)
            let n = saved.withUnsafeMutableBytes { pread(fd, $0.baseAddress, backupBytes, 0) }
            guard n == backupBytes else { throw CarveError.message("Could not read the drive to make a backup.") }
            try Data(saved).write(to: URL(fileURLWithPath: backup))
            chown(backup, uid, gid)
            print("\nBackup of first \(backupBytes >> 20) MB saved to: \(backup)")

            var block = best.data
            let w = block.withUnsafeMutableBytes { pwrite(fd, $0.baseAddress, best.blockSize, 0) }
            guard w == best.blockSize else { throw CarveError.message("Write failed: \(String(cString: strerror(errno)))") }
            fsync(fd)
            print("Restored superblock from backup copy at block \(best.block) (transaction \(best.xid)).")
        }
        print("\n--- Apple fsck_apfs (repair) ---")
        print(shell("/sbin/fsck_apfs", ["-y", device]))
        print("\nRepair finished. Unplug the drive and plug it back in (or click Mount).")
    }

    static func undo(_ device: String, backup: String) throws {
        guard let d = FileManager.default.contents(atPath: backup), d.count == backupBytes else {
            throw CarveError.message("Backup file not found or incomplete: \(backup)")
        }
        let fd = try openDevice(device, write: true)
        defer { close(fd) }
        let w = [UInt8](d).withUnsafeBytes { pwrite(fd, $0.baseAddress, backupBytes, 0) }
        guard w == backupBytes else { throw CarveError.message("Write failed: \(String(cString: strerror(errno)))") }
        fsync(fd)
        print("Drive start restored exactly as it was before the repair.")
    }

    // MARK: Helpers

    static func openDevice(_ path: String, write: Bool) throws -> Int32 {
        let fd = open(path, write ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw CarveError.message("Cannot open \(path): \(String(cString: strerror(errno)))") }
        return fd
    }

    /// Returns the main superblock (if valid) and every valid copy, newest first.
    static func survey(_ fd: Int32) throws -> (Superblock?, [Superblock]) {
        let bs = 4096
        let len = bs * scanBlocks
        var buf = [UInt8](repeating: 0, count: len)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, len, 0) }
        guard n >= bs else { throw CarveError.message("Could not read the drive (\(String(cString: strerror(errno))))") }
        var found: [Superblock] = []
        for b in 0..<(n / bs) {
            let blk = Array(buf[(b * bs)..<((b + 1) * bs)])
            if let sb = parse(blk, at: UInt64(b)) { found.append(sb) }
        }
        let main = found.first { $0.block == 0 }
        let copies = found.filter { $0.block != 0 }.sorted { $0.xid > $1.xid }
        return (main, copies)
    }

    static func parse(_ b: [UInt8], at block: UInt64) -> Superblock? {
        guard b.count >= 4096, b[32] == 0x4E, b[33] == 0x58, b[34] == 0x53, b[35] == 0x42 else { return nil } // "NXSB"
        func le(_ o: Int, _ n: Int) -> UInt64 { (0..<n).reversed().reduce(0) { $0 << 8 | UInt64(b[o + $1]) } }
        let bs = Int(le(36, 4))
        guard bs == 4096, fletcher64(b, count: bs) == le(0, 8) else { return nil }
        return Superblock(block: block, xid: le(16, 8), blockSize: bs, blockCount: le(40, 8), data: b)
    }

    /// APFS object checksum over bytes 8..<count.
    static func fletcher64(_ b: [UInt8], count: Int) -> UInt64 {
        let m: UInt64 = 0xFFFF_FFFF
        var s1: UInt64 = 0, s2: UInt64 = 0
        var i = 8
        while i < count {
            let w = UInt64(b[i]) | UInt64(b[i + 1]) << 8 | UInt64(b[i + 2]) << 16 | UInt64(b[i + 3]) << 24
            s1 = (s1 + w) % m
            s2 = (s2 + s1) % m
            i += 4
        }
        let c1 = m - ((s1 + s2) % m)
        let c2 = m - ((s1 + c1) % m)
        return c2 << 32 | c1
    }

    static func report(main: Superblock?, copies: [Superblock]) {
        if let main {
            print("Main superblock: OK (transaction \(main.xid), size \(formatSize(main.blockCount * UInt64(main.blockSize))))")
        } else {
            print("Main superblock: DAMAGED. This is why the drive won't mount.")
        }
        print("Valid backup copies found: \(copies.count)")
        if let best = copies.first {
            print("Newest backup: block \(best.block), transaction \(best.xid)")
            if let main, best.xid > main.xid { print("Main superblock is older than the newest backup.") }
        }
    }

    static func formatSize(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func shell(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "(could not run \(exe))" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}
