import Foundation
import Darwin

@_silgen_name("forkpty")
private func brewping_forkpty(
    _ amaster: UnsafeMutablePointer<Int32>?,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafePointer<termios>?,
    _ winp: UnsafePointer<winsize>?
) -> pid_t

final class PTYSession {
    static let rows: UInt16 = 40
    static let columns: UInt16 = 120

    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = -1

    private let lock = NSLock()
    private var acc: [UInt8] = []
    private var didExitFlag = false
    private var exitStatusFlag: Int32 = 0
    private let logFD: Int32

    init(logFileURL: URL?) {
        if let url = logFileURL {
            logFD = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            logFD = -1
        }
    }

    deinit {
        if logFD >= 0 { close(logFD) }
        if masterFD >= 0 { close(masterFD) }
    }

    var didExit: Bool {
        lock.lock(); defer { lock.unlock() }
        return didExitFlag
    }

    var exitStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return exitStatusFlag
    }

    var exitClean: Bool {
        let st = exitStatus
        return (st & 0x7f) == 0 && ((st >> 8) & 0xff) == 0
    }

    var exitCodeValue: Int32 {
        let st = exitStatus
        if (st & 0x7f) == 0 { return (st >> 8) & 0xff }
        return -(st & 0x7f)
    }

    var outputLength: Int {
        lock.lock(); defer { lock.unlock() }
        return acc.count
    }

    var outputText: String {
        text(from: 0)
    }

    func text(from offset: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard offset < acc.count else { return "" }
        return String(decoding: acc[offset...], as: UTF8.self)
    }

    func bytes(from offset: Int) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard offset < acc.count else { return [] }
        return Array(acc[offset...])
    }

    func spawn(path: String, argvName: String, environment: [String: String]) throws {
        var ws = winsize(ws_row: Self.rows, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
        let pid = brewping_forkpty(&masterFD, nil, nil, &ws)
        guard pid >= 0 else {
            throw AgentError.ptyFailure("forkpty failed, errno=\(errno)")
        }
        if pid == 0 {
            for (key, value) in environment {
                setenv(key, value, 1)
            }
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(argvName), nil]
            execv(path, &argv)
            exit(127)
        }
        childPID = pid
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "BrewPing PTY reader"
        thread.start()
    }

    func isChildAlive() -> Bool {
        if didExit { return false }
        var st: Int32 = 0
        let result = waitpid(childPID, &st, WNOHANG)
        if result == childPID {
            lock.lock()
            if !didExitFlag {
                exitStatusFlag = st
                didExitFlag = true
            }
            lock.unlock()
            return false
        }
        return result == 0
    }

    @discardableResult
    func write(_ string: String) -> Bool {
        var string = string
        return string.withUTF8 { ptr -> Bool in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return false }
            var written = 0
            while written < ptr.count {
                let n = Darwin.write(masterFD, base + written, ptr.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    func shutdown() -> (clean: Bool, code: Int32) {
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        let deadline = Date().addingTimeInterval(6)
        while !didExit && Date() < deadline {
            usleep(100_000)
        }
        if !didExit {
            kill(childPID, SIGTERM)
            usleep(500_000)
            kill(childPID, SIGKILL)
            let deadline2 = Date().addingTimeInterval(3)
            while !didExit && Date() < deadline2 {
                usleep(100_000)
            }
        }
        return (exitClean, exitCodeValue)
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0 else { continue }
            let n = read(masterFD, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            lock.lock()
            acc.append(contentsOf: buf.prefix(n))
            lock.unlock()
            if logFD >= 0 {
                buf.withUnsafeBytes { raw in
                    _ = Darwin.write(logFD, raw.baseAddress!, n)
                }
            }
        }
        var st: Int32 = 0
        if waitpid(childPID, &st, 0) >= 0 || errno != ECHILD {
            lock.lock()
            if !didExitFlag {
                exitStatusFlag = st
                didExitFlag = true
            }
            lock.unlock()
        } else {
            lock.lock()
            didExitFlag = true
            lock.unlock()
        }
    }
}
