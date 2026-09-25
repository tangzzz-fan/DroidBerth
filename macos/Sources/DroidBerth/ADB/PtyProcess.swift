import Darwin
import Foundation

struct PtyError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class PtyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled {
            kill(pid, SIGTERM)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        lock.unlock()
        guard let target else { return }
        kill(target, SIGTERM)
    }
}

enum PtyProcess {
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cancellation: PtyCancellation? = nil,
        onSegment: @Sendable (String) -> Void
    ) throws -> Int32 {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PtyError(message: "openpty failed: \(String(cString: strerror(errno)))")
        }

        var term = termios()
        if tcgetattr(slave, &term) == 0 {
            term.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
            term.c_oflag &= ~tcflag_t(OPOST)
            term.c_iflag &= ~tcflag_t(ICRNL | INLCR | IXON | IXOFF)
            _ = tcsetattr(slave, TCSANOW, &term)
        }

        var window = winsize(ws_row: 40, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &window)

        var actions: posix_spawn_file_actions_t?
        let initResult = posix_spawn_file_actions_init(&actions)
        guard initResult == 0 else {
            close(master)
            close(slave)
            throw PtyError(message: "posix_spawn_file_actions_init failed: \(String(cString: strerror(initResult)))")
        }
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)

        var cArguments = ([executable.path] + arguments).map { strdup($0) }
        cArguments.append(nil)
        defer { for pointer in cArguments { free(pointer) } }

        var cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer { for pointer in cEnvironment { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid,
            executable.path,
            &actions,
            nil,
            &cArguments,
            &cEnvironment
        )
        posix_spawn_file_actions_destroy(&actions)
        close(slave)

        guard spawnResult == 0 else {
            close(master)
            throw PtyError(message: "posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }

        cancellation?.attach(pid: pid)
        drain(master: master, cancellation: cancellation, onSegment: onSegment)
        close(master)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return exitCode(from: status)
    }

    private static func drain(
        master: Int32,
        cancellation: PtyCancellation?,
        onSegment: @Sendable (String) -> Void
    ) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var pending = ""
        var softKillDeadline: Date?

        while true {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 150)

            if ready < 0, errno != EINTR { break }
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count <= 0 { break }
                pending += String(decoding: buffer[0..<count], as: UTF8.self)
                while let index = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let segment = String(pending[pending.startIndex..<index])
                    pending = String(pending[pending.index(after: index)...])
                    if !segment.isEmpty { onSegment(segment) }
                }
            }

            if cancellation?.isCancelled == true {
                if softKillDeadline == nil {
                    softKillDeadline = Date().addingTimeInterval(2)
                } else if let deadline = softKillDeadline, Date() >= deadline {
                    break
                }
            }
        }

        if !pending.isEmpty { onSegment(pending) }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 { return (status >> 8) & 0xFF }
        if signal != 0x7F { return 128 + signal }
        return -1
    }
}
