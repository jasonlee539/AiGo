import AppKit
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
                        Text("每个项目独立保存 CLI 路径、动态模型目录和角色模型分工。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ModelBadge(modelID: "本机 Codex CLI", effort: nil)
                }

                cliPanel
                catalogPanel
                profilePanel
                executionBoundaryPanel
                storagePanel
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

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("角色模型分工")
                        .font(.headline)
                    Text("每个智能体绑定一个配置；模型与推理强度都可不同，也可以跟随 CLI 默认值。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.addProfile()
                } label: {
                    Label("新增配置", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(engine.isActive)
            }

            ForEach(store.workspace.profiles.indices, id: \.self) { index in
                let profileID = store.workspace.profiles[index].id
                CLIProfileRow(
                    profile: $store.workspace.profiles[index],
                    models: store.workspace.cliSettings.cachedModels,
                    usageCount: store.workspace.agents.filter { $0.profileID == profileID }.count,
                    canDelete: store.workspace.profiles.count > 1,
                    onDelete: { store.deleteProfile(id: profileID) }
                )
                .disabled(engine.isActive)
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
            Text("codex exec --json --ephemeral --sandbox read-only --skip-git-repo-check -C <项目目录> [--model <角色模型>] --config model_reasoning_effort=\"<强度>\" -")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            Text("模型留空时不传 --model，由 Codex CLI 自己选择当前默认模型。0.1.1 只编排和读取结果，不允许模型修改项目文件。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .glassPanel(cornerRadius: 16)
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("项目本地边界", systemImage: "internaldrive.fill")
                .font(.headline)
            pathRow("项目库", store.storageURL.path)

            HStack(alignment: .center, spacing: 9) {
                Text("项目路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                TextField("留空时使用 AiGo 托管目录", text: $store.workspace.projectDirectoryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .disabled(engine.isActive)
                Button("选择文件夹…") { chooseProjectDirectory() }
                    .buttonStyle(.bordered)
                    .disabled(engine.isActive)
                Button("恢复托管") { store.workspace.projectDirectoryPath = "" }
                    .buttonStyle(.bordered)
                    .disabled(store.workspace.projectDirectoryPath.isEmpty || engine.isActive)
            }

            HStack(spacing: 7) {
                Image(systemName: projectPathIsValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(projectPathIsValid ? Color(hex: "4ADE80") : Color(hex: "FBBF24"))
                Text("实际 CLI 工作目录：\(projectDirectoryPath)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Text("可以为每个项目选择现有文件夹。AiGo 不会删除自定义目录；运行时该路径传给 codex exec 的 -C，当前版本仍使用 read-only 沙箱。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = store.migrationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(hex: "A5B4FC"))
                    .textSelection(.enabled)
            }
            if let message = store.persistenceMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(hex: "FB7185"))
            }
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

    private func pathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private var projectDirectoryPath: String {
        store.projectDirectoryDisplayPath(for: store.workspace.id)
    }

    private var projectPathIsValid: Bool {
        let configured = store.workspace.projectDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return true }
        let expanded = (configured as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择“\(store.workspace.projectName)”的项目工作目录"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let current = store.workspace.projectDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            store.workspace.projectDirectoryPath = url.standardizedFileURL.path
        }
    }

    private var cliIsLoggedIn: Bool {
        store.workspace.cliSettings.loginSummary?.localizedCaseInsensitiveContains("logged in") == true
    }
}

private struct CLIProfileRow: View {
    @Binding var profile: CodexProfile
    let models: [CLIModelDescriptor]
    let usageCount: Int
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(hex: "A78BFA"))
                .frame(width: 32, height: 32)
                .background(Color(hex: "6D28D9").opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            TextField("配置名称", text: $profile.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 145)

            Picker("模型", selection: $profile.modelID) {
                Text("跟随 CLI 当前默认").tag("")
                ForEach(models) { model in
                    Text(model.displayName).tag(model.modelID)
                }
                if !profile.modelID.isEmpty && !models.contains(where: { $0.modelID == profile.modelID }) {
                    Text("\(profile.modelID)（目录外）").tag(profile.modelID)
                }
            }
            .labelsHidden()
            .frame(minWidth: 210)

            Picker("推理", selection: $profile.reasoningEffort) {
                ForEach(availableEfforts) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .frame(width: 116)

            Text("\(usageCount) 个角色")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
        }
        .padding(11)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: profile.modelID) { _, _ in
            if !availableEfforts.contains(profile.reasoningEffort) {
                profile.reasoningEffort = selectedModel?.defaultReasoningEffort ?? .medium
            }
        }
    }

    private var selectedModel: CLIModelDescriptor? {
        if profile.modelID.isEmpty {
            return models.first(where: \.isDefault) ?? models.first
        }
        return models.first { $0.modelID == profile.modelID }
    }

    private var availableEfforts: [ReasoningEffort] {
        selectedModel?.supportedReasoningEfforts ?? ReasoningEffort.allCases
    }
}
