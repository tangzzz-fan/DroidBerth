import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                transferSection
                destinationSection
                mediaSection
                listSection
                appearanceSection
                rememberedSection
                diagnosticsSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("设置会立即生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // PRD §25 动态字体：给下限 / 理想值而不是定尺寸，字号放大时表单可以撑开。
        .frame(minWidth: 480, idealWidth: 480, minHeight: 560, idealHeight: 620)
    }

    private var transferSection: some View {
        Section("传输") {
            Picker("同时传输的任务数", selection: $settings.concurrency) {
                ForEach(1...8, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            Picker("目标已存在同名文件", selection: $settings.conflictPolicy) {
                ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            Text(settings.conflictPolicy == .keepBoth
                 ? "保留两者：新文件会自动加上 (1)、(2) 后缀，不覆盖原有内容。"
                 : "覆盖：同名文件会被直接替换，设备端原有内容不可恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("传输面板固定在最下方", isOn: $settings.transferPanelPinned)
            Text("固定后即使没有传输任务也常驻，且不会自动折叠。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationSection: some View {
        Section("上传落点") {
            Toggle("按文件类型自动分流", isOn: $settings.routingEnabled)
            Toggle("记住每台设备上次使用的目录", isOn: $settings.rememberLastDestination)
            Text("视频进 Movies，图片进 DCIM，其它进 Download。设备窗格已经进入具体目录时，以该目录为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mediaSection: some View {
        Section("媒体库") {
            Toggle("上传完成后让设备重新索引", isOn: $settings.scanAfterTransfer)
            Text("推送完成后向设备发送媒体扫描广播，新文件才会出现在手机相册里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var listSection: some View {
        Section("列表") {
            Toggle("文件夹排在最前", isOn: $settings.foldersFirst)
            Text("关闭后文件夹与文件一起按你选的列排序。列头点击排序始终可用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近使用的文件夹")
                    Text("「位置」弹窗里显示 \(settings.recentLocalFolders.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除") { settings.forgetRecentLocalFolders() }
                    .controlSize(.small)
                    .disabled(settings.recentLocalFolders.isEmpty)
            }
        }
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var rememberedSection: some View {
        Section("已记住的无线设备") {
            let devices = settings.rememberedWirelessDevices
            if devices.isEmpty {
                Text("还没有记住任何无线设备。先用数据线连接手机，再点「启用无线连接」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices, id: \.serial) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.serial).font(.callout)
                            Text(device.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("忘记") { settings.forgetAddress(for: device.serial) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    /// 诊断（日志与崩溃收集）。
    ///
    /// 刻意**不做成独立窗口**：它一年用不了几次，塞在设置里只占三行，
    /// 比多一个窗口更符合「界面简洁」。导出这一步会真的跑一遍自检，所以要给进度。
    private var diagnosticsSection: some View {
        Section("诊断") {
            LabeledContent("日志") {
                Text(AppPaths.logsDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("导出诊断报告…") {
                    Task { await model.exportDiagnostics() }
                }
                .disabled(model.diagnosticsExporting)
                Button("在访达中显示") { model.revealLogs() }
                if model.diagnosticsExporting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            Text("诊断包含日志、系统崩溃报告、自检结果与设备状态。用户名、设备序列号与密钥指纹在写入前就会被抹掉；**不会**自动上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
