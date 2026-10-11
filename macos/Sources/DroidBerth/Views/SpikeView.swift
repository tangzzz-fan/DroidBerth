import Observation
import SwiftUI

@MainActor
@Observable
final class SpikeModel {
    var rows: [SpikeRow] = []
    var running = false
    var hasRun = false
    var finishedAt: Date?

    func run() {
        guard !running else { return }
        running = true
        hasRun = true
        rows = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SpikeChecks.runAll()
            SpikeReportWriter.write(result)
            // 回主 actor 用**直接 await 一个 @MainActor 方法**，不要用
            // `MainActor.run { self.rows = … }` —— 后者的 body 是 `@Sendable`，
            // 捕获 self 会被判 `sending 'self' risks causing data races`
            // （Xcode 16.4 报，新编译器不报）。
            guard let self else { return }
            await self.apply(result)
        }
    }

    private func apply(_ result: [SpikeRow]) {
        rows = result
        running = false
        finishedAt = Date()
    }
}

struct SpikeView: View {
    @State private var model = SpikeModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { model.run() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Swift 原生外壳验证").font(.headline)
                Text("V1 定位 · V2 签名链 · V3 进程封装 · V4 端到端")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.running {
                ProgressView().controlSize(.small)
            }
            Button(model.running ? "运行中…" : "重新运行") { model.run() }
                .disabled(model.running)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            VStack(spacing: 8) {
                if model.running {
                    ProgressView()
                    Text("正在运行验证项…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("无结果").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.rows) { row in
                SpikeRowView(row: row)
            }
            .listStyle(.inset)
        }
    }
}

private struct SpikeRowView: View {
    let row: SpikeRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(row.title).font(.headline)
                    Text(row.status.rawValue.uppercased())
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(tint)
                }
                Text(row.evidence)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch row.status {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .manual: "questionmark.circle"
        case .skip: "minus.circle"
        }
    }

    private var tint: Color {
        switch row.status {
        case .pass: .green
        case .fail: .red
        case .manual: .orange
        case .skip: .secondary
        }
    }
}
