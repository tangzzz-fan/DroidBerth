import Foundation

struct TransferPlan: Sendable, Hashable {
    enum Direction: String, Sendable {
        case upload
        case download

        var label: String { self == .upload ? "上传" : "下载" }
        var symbol: String { self == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill" }
    }

    let serial: String
    let direction: Direction
    let localPath: String
    let remotePath: String
    let displayName: String
    let totalBytes: Int64?

    var destinationDirectory: String {
        (remotePath as NSString).deletingLastPathComponent
    }
}

@MainActor
@Observable
final class TransferJob: Identifiable {
    enum State: Sendable {
        case waiting
        case running
        case finished
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .finished, .failed, .cancelled: true
            default: false
            }
        }
    }

    let id = UUID()
    let plan: TransferPlan

    var state: State = .waiting
    var fraction: Double = 0
    var bytesTransferred: Int64 = 0
    var bytesPerSecond: Double?
    var estimatedRemaining: Double?
    var errorMessage: String?
    var mediaScanNote: String?
    var mediaScanFailed = false
    var startedAt: Date?
    var finishedAt: Date?

    var direction: TransferPlan.Direction { plan.direction }
    var displayName: String { plan.displayName }
    var totalBytes: Int64? { plan.totalBytes }

    init(plan: TransferPlan) {
        self.plan = plan
    }

    func apply(_ parsed: ParsedProgress) {
        if let percent = parsed.percent {
            fraction = min(max(percent / 100, 0), 1)
            if let total = plan.totalBytes {
                bytesTransferred = Int64(Double(total) * fraction)
            }
        }
        if let bytes = parsed.completedBytes {
            bytesTransferred = bytes
            fraction = 1
        }
        if let speed = parsed.bytesPerSecond, speed > 0 {
            bytesPerSecond = speed
            if let total = plan.totalBytes {
                let remaining = Double(max(total - bytesTransferred, 0)) / speed
                estimatedRemaining = remaining > 0 ? remaining : nil
            }
        }
        if let error = parsed.errorText {
            errorMessage = error
        }
    }

    var statusText: String {
        switch state {
        case .waiting: "等待中"
        case .running: "\(Int(fraction * 100))%"
        case .finished: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    var detailText: String {
        switch state {
        case .waiting:
            return ByteFormat.size(plan.totalBytes)
        case .running:
            var parts: [String] = []
            if let total = plan.totalBytes {
                parts.append("\(ByteFormat.size(bytesTransferred)) / \(ByteFormat.size(total))")
            } else {
                parts.append(ByteFormat.size(bytesTransferred))
            }
            if let speed = bytesPerSecond { parts.append(ByteFormat.speed(speed)) }
            if let remaining = estimatedRemaining { parts.append("剩余 \(ByteFormat.remaining(remaining))") }
            return parts.joined(separator: " · ")
        case .finished:
            return ByteFormat.size(plan.totalBytes) + " · " + (mediaScanNote ?? "完成")
        case .failed:
            return errorMessage ?? "失败"
        case .cancelled:
            return "已取消"
        }
    }
}
