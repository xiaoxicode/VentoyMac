import Foundation
import VentoyCore

struct CommandResult: Sendable {
    let stdout: Data
    let stderr: String
    let status: Int32

    var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
}

enum RunnerError: Error, LocalizedError {
    case launchFailed(String)
    case commandFailed(Int32, String)
    case privilegedCancelled
    case privilegedFailed(String)
    case diskAccessDenied(String)
    case unalignedRawWrite(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return "无法启动进程：\(message)"
        case .commandFailed(let code, let message): return "命令失败（退出码 \(code)）：\(message)"
        case .privilegedCancelled: return "已取消管理员授权，未对磁盘做任何写入。"
        case .privilegedFailed(let message): return "提权执行失败：\(message)"
        case .diskAccessDenied(let detail):
            return """
            磁盘写入被系统拒绝（Operation not permitted / EPERM）。

            /bin/dd 与 /usr/sbin/gpt 都没有 macOS 的
            com.apple.private.security.disk-device-access 授权，能否写 /dev/rdisk*
            取决于 TCC 认定的「责任进程」是否拥有「完全磁盘访问」(FDA)，
            root 也不能绕过。脚本已在任何破坏性命令之前中止，U 盘数据未被修改
            （可能只是被卸载了，重新插拔即可恢复）。

            不通过终端解决（按顺序）：
              1. 系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加并启用 VentoyMac.app
              2. 完全退出 VentoyMac 并重新打开（授权只在进程启动时生效）
              3. 应用「安装」页 → 「验证磁盘写入权限」，会自动挑选可用通道
              4. 若仍失败：把 /usr/libexec/security_authtrampoline 也加入
                 「完全磁盘访问」（在添加面板按 Cmd-Shift-G 粘贴该路径）。
                 这是提权时真正被 TCC 判定的进程，应用内按钮可一键复制路径。
                 添加后完全退出并重开 VentoyMac。

            备用：导出脚本，在已获 FDA 的终端中执行 sudo bash <脚本路径>。

            脚本末尾输出：
            \(detail)
            """
        case .unalignedRawWrite(let detail):
            return """
            裸盘写入被内核以 Invalid argument (EINVAL) 拒绝——这不是权限问题，
            而是 /dev/rdisk* 强制要求「传输长度与字节偏移都是 512 字节的整数倍」。
            官方 Linux 脚本的 bs=64 / bs=1 写法依赖页缓存，不能直接用于 macOS 裸设备。

            当前版本已把全部写入改为 bs=512 整扇区，并把子扇区字节补丁
            （字节 92 / 17908 / 384 / 440）先落在 $VTOY_STAGE 的普通文件中再写回。
            如果仍看到此错误，请确认运行的是最新重新构建的 VentoyMac.app，
            并用「导出脚本」检查是否还有 bs=1 / bs=64 的裸设备写入。

            脚本末尾输出：
            \(detail)
            """
        }
    }
}

enum ProcessRunner {

    /// How the root script is launched. TCC decides Full Disk Access by the
    /// *responsible* process, and `security_authtrampoline` does not pass the
    /// calling app's grant through. `.signedHelper` therefore execs an
    /// in-bundle binary whose designated requirement is identical to the
    /// app's, so the grant matches the process that actually spawns `dd`.
    enum PrivilegedChannel: String {
        case signedHelper
        case directBash
    }

    /// Absolute path of the elevated writer helper. `VentoyWriter.app` is a
    /// real nested bundle (with its own Info.plist) so it can satisfy the same
    /// `identifier + CFBundleVersion` designated requirement as the app.
    /// Falls back to the plain CLI when running from `swift run`.
    static var helperPath: String? {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent(
                "Contents/Resources/VentoyWriter.app/Contents/MacOS/VentoyWriter").path,
            bundle.appendingPathComponent("Contents/MacOS/ventoymac-cli").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command without a shell. Output goes to temp files so large
    /// plist/dd output can never deadlock on a pipe buffer.
    static func run(_ launchPath: String, _ arguments: [String]) async throws -> CommandResult {
        let tag = UUID().uuidString
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vtoymac-\(tag).out")
        let errURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vtoymac-\(tag).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let outHandle: FileHandle
        let errHandle: FileHandle
        do {
            outHandle = try FileHandle(forWritingTo: outURL)
            errHandle = try FileHandle(forWritingTo: errURL)
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = outHandle
            process.standardError = errHandle
            process.terminationHandler = { finished in
                try? outHandle.close()
                try? errHandle.close()
                let output = (try? Data(contentsOf: outURL)) ?? Data()
                let errorText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                continuation.resume(returning: CommandResult(stdout: output,
                                                             stderr: errorText,
                                                             status: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Runs an entire generated script as root via AppleScript's
    /// `do shell script ... with administrator privileges`, tailing its log.
    /// The onLog closure may be called from any thread.
    static func runPrivileged(script: String,
                              channel: PrivilegedChannel = .signedHelper,
                              onLog: @escaping (String) -> Void) async throws -> Int32 {
        let (status, _) = try await runPrivilegedCollecting(script: script,
                                                            channel: channel,
                                                            onLog: onLog)
        return status
    }

    /// Same as `runPrivileged`, but also returns the complete combined log.
    static func runPrivilegedCollecting(script: String,
                                        channel: PrivilegedChannel = .signedHelper,
                                        onLog: @escaping (String) -> Void) async throws -> (Int32, String) {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vtoymac-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let scriptURL = work.appendingPathComponent("install.sh")
        let logURL = work.appendingPathComponent("install.log")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let q = ShellQuote.bash
        let useHelper = channel == .signedHelper && helperPath != nil
        let command: String
        if useHelper, let helper = helperPath {
            command = "\(q(helper)) run-script \(q(scriptURL.path)) > \(q(logURL.path)) 2>&1"
        } else {
            command = "/bin/bash \(q(scriptURL.path)) > \(q(logURL.path)) 2>&1"
        }
        let appleScript = "do shell script \"\(ShellQuote.appleScript(command))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errHandle = Pipe()
        process.standardError = errHandle
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        var offset: UInt64 = 0
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let (chunk, next) = tail(logURL, from: offset)
            offset = next
            if !chunk.isEmpty { onLog(chunk) }
        }
        let (chunk, _) = tail(logURL, from: offset)
        if !chunk.isEmpty { onLog(chunk) }

        let errData = errHandle.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        let status = process.terminationStatus
        let fullLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

        if status != 0 {
            if errText.contains("-128") || errText.lowercased().contains("user canceled") {
                throw RunnerError.privilegedCancelled
            }
            let lastLines = fullLog.split(separator: "\n").suffix(18).joined(separator: "\n")
            let combined = errText + "\n" + fullLog
            if combined.contains("Operation not permitted")
                || combined.contains("(EPERM)")
                || combined.contains("拒绝执行：当前进程无法") {
                throw RunnerError.diskAccessDenied(lastLines)
            }
            if combined.contains("dd: /dev/rdisk") && combined.contains("Invalid argument") {
                throw RunnerError.unalignedRawWrite(lastLines)
            }
            throw RunnerError.privilegedFailed(errText.isEmpty ? lastLines : "\(errText)\n\(lastLines)")
        }
        return (status, fullLog)
    }

    /// Runs a generated script as the CURRENT user (no escalation).
    ///
    /// Retained for diagnostics only — NOT a usable install path on macOS:
    /// /dev/disk* is `root:operator rw-r-----` (group has read only), and
    /// `diskutil partitionDisk` / `newfs_exfat` on a physical USB disk need
    /// euid 0. Kept as a low-risk probe
    /// so the UI can report the exact errno of the unprivileged path.
    static func runCurrentUser(script: String,
                               onLog: @escaping (String) -> Void) async throws -> (Int32, String) {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vtoymac-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let scriptURL = work.appendingPathComponent("install.sh")
        let logURL = work.appendingPathComponent("install.log")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        var offset: UInt64 = 0
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let (chunk, next) = tail(logURL, from: offset)
            offset = next
            if !chunk.isEmpty { onLog(chunk) }
        }
        try? logHandle.close()
        let (chunk, _) = tail(logURL, from: offset)
        if !chunk.isEmpty { onLog(chunk) }

        let status = process.terminationStatus
        let fullLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if status != 0 {
            let lastLines = fullLog.split(separator: "\n").suffix(18).joined(separator: "\n")
            if fullLog.contains("Operation not permitted")
                || fullLog.contains("拒绝执行：当前进程无法")
                || fullLog.contains("Permission denied") {
                throw RunnerError.diskAccessDenied(lastLines)
            }
            if fullLog.contains("dd: /dev/rdisk") && fullLog.contains("Invalid argument") {
                throw RunnerError.unalignedRawWrite(lastLines)
            }
            throw RunnerError.commandFailed(status, lastLines)
        }
        return (status, fullLog)
    }

    /// Zero-byte raw-disk probe through the privileged AppleScript path.
    /// Throws exactly the same errors a real install would throw, so the UI
    /// can tell in advance whether app-internal writing will work.
    static func probePrivileged(bsdName: String,
                                channel: PrivilegedChannel = .signedHelper) async throws -> String {
        let (_, log) = try await runPrivilegedCollecting(
            script: DiskAccessProbe.script(bsdName: bsdName),
            channel: channel) { _ in }
        return log
    }

    /// Runs a non-privileged script (audit mode) and returns combined output.
    static func runScript(_ script: String) async throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vtoymac-audit-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let result = try await run("/bin/bash", [url.path])
        let text = result.stdoutString + result.stderr
        guard result.status == 0 else {
            throw RunnerError.commandFailed(result.status, text)
        }
        return text
    }

    private static func tail(_ url: URL, from offset: UInt64) -> (String, UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", offset) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > offset else { return ("", offset) }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "", offset + UInt64(data.count))
    }
}
