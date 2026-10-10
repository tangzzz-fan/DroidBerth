import AppKit
import SwiftUI

/// 传输面板（PRD §14）。
///
/// 行为约定：
/// - 无任务时隐藏（由 `MainView` 判断），有任务时自动展开，可手动折叠
/// - **固定（pin）**后即使队列为空也常驻，且不参与自动折叠
/// - 失败行常驻显示「重试」与「查看原因」，不藏在 hover 后面 —— 失败需要被看见
struct TransferPanel: View {
    @Bindable var queue: TransferQueue
    @Bindable var settings: AppSettings
    @State private var userExpanded = true
    /// PRD §25：Reduce Motion 时把折叠动画退化成无动画（展开/收起本身仍然发生）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pinned: Bool { settings.transferPanelPinned }
    private var expanded: Bool { pinned || userExpanded }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                list
            }
        }
        .background(.bar)
        // PRD §14「有任务时自动展开」。只在「空闲 → 有任务」这个跳变上展开：
        // 用户在传输进行中手动折叠后，不该被下一帧重新弹开。
        .onChange(of: queue.hasActive) { _, active in
            if active { userExpanded = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if queue.hasActive {
                ProgressView().controlSize(.small)
            } else if queue.failed.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            Text(queue.summaryText).font(.callout)

            if !queue.notes.isEmpty, expanded {
                Text(queue.notes.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !queue.failed.isEmpty {
                Button("全部重试") { queue.retryFailed() }
                    .controlSize(.small)
            }
            if queue.hasActive {
                Button("全部取消") { queue.cancelAll() }
                    .controlSize(.small)
            } else {
                Button("清除已完成") { queue.clearFinished() }
                    .controlSize(.small)
                    .disabled(queue.jobs.allSatisfy { $0.state == .failed })
            }

            Button {
                settings.transferPanelPinned.toggle()
                if settings.transferPanelPinned { userExpanded = true }
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(pinned ? "取消固定：队列为空时自动隐藏" : "固定面板：队列为空时也常驻")

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { userExpanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(pinned)
            .help(pinned ? "已固定，无法折叠" : (expanded ? "折叠" : "展开"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(orderedJobs) { job in
                    TransferRow(
                        job: job,
                        onCancel: { queue.cancel(job) },
                        onRetry: { queue.retry(job) }
                    )
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: 190)
    }

    /// 进行中 / 等待中的排前面，终态的按结束时间新→旧。
    private var orderedJobs: [TransferJob] {
        let active = queue.jobs.filter { !$0.state.isTerminal }
        let done = queue.jobs
            .filter { $0.state.isTerminal }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        return active + done
    }
}

private struct TransferRow: View {
    let job: TransferJob
    let onCancel: () -> Void
    let onRetry: () -> Void

    @State private var showsDetail = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFailed: Bool { job.state == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainLine
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isFailed ? Color.red.opacity(0.07) : Color.clear)
                .onHover { hovering = $0 }

            if showsDetail {
                detail
            }
        }
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            Image(systemName: job.direction.symbol)
                .foregroundStyle(TransferDirectionTint.color(for: job.direction))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.displayName).lineLimit(1).truncationMode(.middle)
                    Text(job.direction.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(job.detailText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if job.state == .running || job.state == .waiting {
                ProgressView(value: job.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
            } else if job.state == .finished {
                Image(systemName: job.mediaScanFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(job.mediaScanFailed ? .orange : .green)
            } else if isFailed {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }

            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isFailed {
            // 失败不藏在 hover 后面：这是用户必须处理的状况。
            Button("重试", action: onRetry)
                .controlSize(.small)
            Button(showsDetail ? "收起" : "查看原因") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { showsDetail.toggle() }
            }
            .controlSize(.small)
        } else if job.state == .running || job.state == .waiting {
            // PRD §14：取消按钮 hover 时显示，避免列表里一排叉号。
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("取消")
            .frame(width: 18)
        } else if job.mediaScanFailed, let note = job.mediaScanNote {
            Text(note)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = job.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                pathLine(label: "源", value: job.sourceDescription)
                pathLine(label: "目标", value: job.destinationDescription)
                if let note = job.mediaScanNote, !note.isEmpty {
                    pathLine(label: "入库", value: note)
                }
            }

            Button("拷贝原因") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.leading, 28)
    }

    private func pathLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private var copyText: String {
        var lines = ["\(job.direction.label)：\(job.displayName)"]
        if let message = job.errorMessage { lines.append("原因：\(message)") }
        lines.append("源：\(job.sourceDescription)")
        lines.append("目标：\(job.destinationDescription)")
        return lines.joined(separator: "\n")
    }
}
