import SwiftUI

struct TransferPanel: View {
    @Bindable var queue: TransferQueue
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                list
            }
        }
        .background(.bar)
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
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(expanded ? "折叠" : "展开")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(orderedJobs) { job in
                    TransferRow(job: job, onCancel: { queue.cancel(job) })
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: 190)
    }

    private var orderedJobs: [TransferJob] {
        let active = queue.jobs.filter { !$0.state.isTerminal }
        let done = queue.jobs.filter { $0.state.isTerminal }
        return active + done
    }
}

private struct TransferRow: View {
    let job: TransferJob
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.direction.symbol)
                .foregroundStyle(job.direction == .upload ? Color.accentColor : Color.teal)
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
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
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
            } else if job.state == .failed {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }

            if job.state == .running || job.state == .waiting {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("取消")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
