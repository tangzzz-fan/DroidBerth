import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let durationMs: Int
    let spawnError: String?

    var ok: Bool {
        spawnError == nil && !timedOut && exitCode == 0
    }
}

private final class OutputDrain: @unchecked Sendable {
    private let outHandle: FileHandle
    private let errHandle: FileHandle
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var outData = Data()
    private var errData = Data()
    private var pending = 0

    init(stdout: Pipe, stderr: Pipe) {
        outHandle = stdout.fileHandleForReading
        errHandle = stderr.fileHandleForReading
    }

    func start(on queue: DispatchQueue) {
        pending = 2
        queue.async { [self] in pump(outHandle, isStdout: true) }
        queue.async { [self] in pump(errHandle, isStdout: false) }
    }

    func waitForFinish(_ seconds: TimeInterval) {
        _ = done.wait(timeout: .now() + seconds)
    }

    var stdout: String { text(outData) }
    var stderr: String { text(errData) }

    private func text(_ data: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private func pump(_ handle: FileHandle, isStdout: Bool) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lock.lock()
            if isStdout {
                outData.append(chunk)
            } else {
                errData.append(chunk)
            }
            lock.unlock()
        }
        lock.lock()
        pending -= 1
        let finished = pending == 0
        lock.unlock()
        if finished {
            done.signal()
        }
    }
}

enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let drain = OutputDrain(stdout: outPipe, stderr: errPipe)

        do {
            try process.run()
        } catch {
            return ProcessResult(
                exitCode: nil,
                stdout: "",
                stderr: "",
                timedOut: false,
                durationMs: elapsed(since: started),
                spawnError: String(describing: error)
            )
        }

        let queue = DispatchQueue(
            label: "dev.tango.droidberth.pipe",
            qos: .userInitiated,
            attributes: .concurrent
        )
        drain.start(on: queue)

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < grace {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        drain.waitForFinish(3)

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: drain.stdout,
            stderr: drain.stderr,
            timedOut: timedOut,
            durationMs: elapsed(since: started),
            spawnError: nil
        )
    }

    private static func elapsed(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
