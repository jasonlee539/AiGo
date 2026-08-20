import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var engine: OrchestrationEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codex 设置 · \(store.workspace.projectName)")
                            .font(.title3.weight(.bold))
                        Text("管理本机 CLI 连接和动态模型目录；角色模型请在编排蓝图中设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ModelBadge(modelID: "本机 Codex CLI", effort: nil)
                }

                cliPanel
                catalogPanel
                executionBoundaryPanel
            }
            .padding(14)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }

    private var cliPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("本机 Codex CLI", systemImage: "terminal.fill")
                    .font(.headline)
                Spacer()
                if store.isRefreshingCLI {
                    ProgressView().controlSize(.small)
                }
                Label(
                    cliIsLoggedIn ? "已复用 CLI 登录" : "尚未确认登录",
                    systemImage: cliIsLoggedIn ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(cliIsLoggedIn ? Color(hex: "4ADE80") : Color(hex: "FBBF24"))
            }

            HStack(spacing: 10) {
                Text("可执行文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                TextField("/opt/homebrew/bin/codex", text: $store.workspace.cliSettings.executablePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .disabled(engine.isActive)
                Button {
                    Task { await store.refreshCodexCLI() }
                } label: {
                    Label("检测并刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "5965E8"))
                .disabled(store.isRefreshingCLI || engine.isActive)
            }

            HStack(spacing: 22) {
                statusValue("CLI 版本", store.workspace.cliSettings.cliVersion ?? "未检测")
                statusValue("登录状态", store.workspace.cliSettings.loginSummary ?? "未检测")
                statusValue(
                    "最近刷新",
                    store.workspace.cliSettings.lastRefreshedAt?.formatted(date: .abbreviated, time: .shortened) ?? "从未"
                )
            }

            if let message = store.cliMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(cliIsLoggedIn ? Color.secondary : Color(hex: "FBBF24"))
            }

            Text("AiGo 不读取、保存或转发 API Key；子进程直接使用你已经登录的 Codex CLI 账户。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .glassPanel(cornerRadius: 16, emphasized: true)
    }

    private var catalogPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLI 动态模型目录")
                        .font(.headline)
                    Text("来自当前安装的 Codex CLI；刷新后按本机实际可见模型生成选择器。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.workspace.cliSettings.cachedModels.count) 个可选模型")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if store.workspace.cliSettings.cachedModels.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(Color(hex: "FBBF24"))
                    Text("点击“检测并刷新”读取模型；在此之前，各角色仍可跟随 CLI 默认模型运行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 9)], spacing: 9) {
                    ForEach(store.workspace.cliSettings.cachedModels) { model in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.callout.weight(.semibold))
                                    Text(model.modelID)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.isDefault {
                                    Text("目录首选")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color(hex: "A5B4FC"))
                                }
                            }
                            HStack(spacing: 4) {
                                ForEach(model.supportedReasoningEfforts) { effort in
                                    Text(effort.rawValue)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.055), in: Capsule())
                                }
                            }
                        }
                        .padding(11)
                        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
        }
        .padding(15)
        .glassPanel(cornerRadius: 16)
    }

    private var executionBoundaryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("实际执行边界", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            Text("每个步骤单独启动一次本机进程，提示词通过标准输入传入：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("codex exec --json --ephemeral --sandbox <read-only|workspace-write> --skip-git-repo-check -C <项目目录> [--model <角色模型>] --config model_reasoning_effort=\"<强度>\" -")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            Text("模型留空时不传 --model，由 Codex CLI 自己选择当前默认模型。新建与旧格式迁移步骤默认使用 workspace-write；审核员步骤默认保持 read-only，也可在蓝图中逐步调整。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .glassPanel(cornerRadius: 16)
    }

    private func statusValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private var cliIsLoggedIn: Bool {
        store.workspace.cliSettings.loginSummary?.localizedCaseInsensitiveContains("logged in") == true
    }
}
