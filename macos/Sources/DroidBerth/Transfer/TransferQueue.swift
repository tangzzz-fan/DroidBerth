import Foundation

@MainActor
@Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob] = []
    private(set) var notes: [String] = []

    private var cancellations: [UUID: PtyCancellation] = [:]

    var maxConcurrency: Int { max(1, AppSettings.shared.concurrency) }

    var running: [TransferJob] { jobs.filter { $0.state == .running } }
    var waiting: [TransferJob] { jobs.filter { $0.state == .waiting } }
    var failed: [TransferJob] { jobs.filter { $0.state == .failed } }
    var finished: [TransferJob] { jobs.filter { $0.state == .finished } }
    var hasActive: Bool { jobs.contains { !$0.state.isTerminal } }
    var isEmpty: Bool { jobs.isEmpty }

    var summaryText: String {
        var parts: [String] = []
        if !running.isEmpty { parts.append("\(running.count) 个传输中") }
        if !waiting.isEmpty { parts.append("\(waiting.count) 个等待") }
        if !failed.isEmpty { parts.append("\(failed.count) 个失败") }
        if parts.isEmpty {
            parts.append("\(finished.count) 个已完成")
        }
        return parts.joined(separator: " · ")
    }

    var overallFraction: Double {
        let relevant = jobs.filter { $0.state != .waiting || true }
        guard !relevant.isEmpty else { return 0 }
        let total = relevant.reduce(0.0) { $0 + ($1.state == .finished ? 1 : $1.fraction) }
        return total / Double(relevant.count)
    }

    func enqueue(plans: [TransferPlan], notes: [String]) {
        guard !plans.isEmpty else {
            self.notes = notes
            return
        }
        jobs.append(contentsOf: plans.map { TransferJob(plan: $0) })
        self.notes = notes
        pump()
    }

    func cancel(_ job: TransferJob) {
        guard !job.state.isTerminal else { return }
        job.state = .cancelled
        cancellations[job.id]?.cancel()
    }

    func cancelAll() {
        for job in jobs where !job.state.isTerminal {
            cancel(job)
        }
    }

    func retryFailed() {
        for job in jobs where job.state == .failed {
            job.state = .waiting
            job.fraction = 0
            job.bytesTransferred = 0
            job.errorMessage = nil
            job.mediaScanNote = nil
            job.mediaScanFailed = false
        }
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal && $0.state != .failed }
        if jobs.isEmpty { notes = [] }
    }

    func clearAll() {
        guard !hasActive else { return }
        jobs.removeAll()
        notes = []
    }

    private func pump() {
        while cancellations.count < maxConcurrency {
            guard let next = jobs.first(where: { $0.state == .waiting }) else { break }
            start(next)
        }
    }

    private func start(_ job: TransferJob) {
        job.state = .running
        job.startedAt = Date()

        let cancellation = PtyCancellation()
        cancellations[job.id] = cancellation

        let plan = job.plan
        let shouldScan = AppSettings.shared.scanAfterTransfer

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.execute(plan: plan, cancellation: cancellation) { segment in
                guard let parsed = ProgressParser.parse(segment) else { return }
                Task { @MainActor in job.apply(parsed) }
            }

            var scanNote: String?
            var scanFailed = false
            if outcome.code == 0, plan.direction == .upload, shouldScan {
                if let adb = ADBBinary.shared.path {
                    let shell = DeviceShell(adb: adb, serial: plan.serial)
                    let results = MediaScanner.scan(shell: shell, remotePaths: [plan.remotePath])
                    if let result = results.first {
                        scanNote = result.indexed ? "已进入相册索引" : result.detail
                        scanFailed = !result.indexed
                    }
                }
            }

            await MainActor.run {
                self?.finish(
                    job,
                    outcome: outcome,
                    cancelled: cancellation.isCancelled,
                    scanNote: scanNote,
                    scanFailed: scanFailed
                )
            }
        }
    }

    private func finish(
        _ job: TransferJob,
        outcome: TransferOutcome,
        cancelled: Bool,
        scanNote: String?,
        scanFailed: Bool
    ) {
        cancellations.removeValue(forKey: job.id)
        job.finishedAt = Date()
        job.mediaScanNote = scanNote
        job.mediaScanFailed = scanFailed

        if cancelled || job.state == .cancelled {
            job.state = .cancelled
        } else if outcome.code == 0 {
            job.state = .finished
            job.fraction = 1
            if let total = job.plan.totalBytes { job.bytesTransferred = total }
        } else {
            job.state = .failed
            if job.errorMessage == nil {
                job.errorMessage = outcome.spawnError ?? (outcome.tail.isEmpty
                    ? "adb 退出码 \(outcome.code)"
                    : outcome.tail)
            }
        }

        pump()
    }

    private nonisolated static func execute(
        plan: TransferPlan,
        cancellation: PtyCancellation,
        onSegment: @escaping @Sendable (String) -> Void
    ) -> TransferOutcome {
        guard let adb = ADBBinary.shared.path else {
            return TransferOutcome(code: 127, spawnError: "未找到 adb 可执行文件", tail: "")
        }

        var arguments = ["-s", plan.serial]
        switch plan.direction {
        case .upload:
            arguments.append(contentsOf: ["push", plan.localPath, plan.remotePath])
        case .download:
            arguments.append(contentsOf: ["pull", plan.remotePath, plan.localPath])
        }

        let tailBox = TailBox()
        do {
            let code = try PtyProcess.run(
                executable: adb,
                arguments: arguments,
                cancellation: cancellation,
                onSegment: { segment in
                    tailBox.append(segment)
                    onSegment(segment)
                }
            )
            return TransferOutcome(code: code, spawnError: nil, tail: tailBox.tail)
        } catch {
            return TransferOutcome(code: 126, spawnError: String(describing: error), tail: tailBox.tail)
        }
    }
}

struct TransferOutcome: Sendable {
    let code: Int32
    let spawnError: String?
    let tail: String
}

private final class TailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > 12 { lines.removeFirst(lines.count - 12) }
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { !$0.hasPrefix("[") }.suffix(3).joined(separator: " · ")
    }
}
