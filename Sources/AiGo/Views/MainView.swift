import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var runRegistry: ProjectRunRegistry
    @State private var recoveryCheckpoint: RunCheckpoint?

    private var currentEngine: OrchestrationEngine {
        runRegistry.engine(for: store.workspace.id)
    }

    var body: some View {
        ZStack {
            AiGoBackground()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(Color.white.opacity(0.08))
                    detail
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $recoveryCheckpoint) { checkpoint in
            RunRecoveryView(
                checkpoint: checkpoint,
                project: store.workspace,
                restart: {
                    let engine = runRegistry.engine(for: checkpoint.projectID)
                    if RunLaunchCoordinator.restart(store: store, engine: engine, checkpoint: checkpoint) {
                        recoveryCheckpoint = nil
                    }
                },
                resume: {
                    let engine = runRegistry.engine(for: checkpoint.projectID)
                    if RunLaunchCoordinator.resume(store: store, engine: engine, checkpoint: checkpoint) {
                        recoveryCheckpoint = nil
                    }
                }
            )
            .interactiveDismissDisabled()
        }
        .task(id: store.workspace.id) {
            await Task.yield()
            presentRecoveryIfNeeded()
            if store.workspace.cliSettings.cachedModels.isEmpty
                || store.workspace.cliSettings.loginSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                await store.refreshCodexCLI()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppBrandIcon()
                .padding(6)
                .frame(width: 40, height: 40)
                .background(Color(hex: "E7E9EC"), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("AiGo")
                        .font(.headline.weight(.bold))
                    Text("0.1.4")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                Text("本机 Codex 科研编排台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("当前项目")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("项目名称", text: $store.workspace.projectName)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: 360)
                    .disabled(currentEngine.isActive)
            }

            Spacer()

            Button(action: chooseProjectDirectory) {
                Label(projectFolderName, systemImage: "folder.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentEngine.isActive)
            .help("更改项目文件夹")
            .contextMenu {
                Button("恢复 AiGo 托管目录") {
                    store.workspace.projectDirectoryPath = ""
                }
                .disabled(store.workspace.projectDirectoryPath.isEmpty || currentEngine.isActive)
            }

            Text("\(store.projects.count) 个项目 · \(store.workspace.agents.count)/\(WorkspaceRules.maxAgents) 智能体")
                .font(.caption)
                .foregroundStyle(.secondary)
            if runRegistry.activeCount > 1 {
                Text("\(runRegistry.activeCount) 个项目并行")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(hex: "4ADE80"))
            }
            ModelBadge(modelID: "Codex CLI", effort: nil)
            RunStatusBadge(phase: currentEngine.session.phase)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(Color(hex: "1D2024"))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("项目工作区")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    store.addProject()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建独立科研项目")
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.projects) { project in
                        projectGroup(project)
                    }
                }
                .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(cliIsLoggedIn ? Color(hex: "22C55E") : Color(hex: "F59E0B"))
                        .frame(width: 7, height: 7)
                    Text(cliIsLoggedIn ? "本机 CLI 已登录" : "等待 CLI 登录检测")
                        .font(.caption.weight(.semibold))
                }
                Text("动态模型目录：\(store.workspace.cliSettings.cachedModels.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(runRegistry.activeCount == 0
                     ? "每个项目独立保存蓝图、运行、记忆和设置"
                     : "当前有 \(runRegistry.activeCount) 个项目独立运行")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 13)
            .padding(10)
        }
        .frame(width: 252)
        .background(Color(hex: "1B1E21"))
    }

    private func projectGroup(_ project: ProjectWorkspace) -> some View {
        let selected = project.id == store.workspace.id
        let projectEngine = runRegistry.engine(for: project.id)
        return VStack(spacing: 3) {
            Button {
                store.selectProject(project.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "folder.fill" : "folder")
                        .foregroundStyle(selected ? Color(hex: "6FA8DC") : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.projectName)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                        Text("\(project.steps.count) 步 · \(project.agents.count) 角色")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if projectEngine.isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .help("此项目正在独立运行")
                    } else if projectEngine.session.phase != .idle {
                        Circle()
                            .fill(projectEngine.session.phase == .completed ? Color(hex: "22C55E") : Color(hex: "F59E0B"))
                            .frame(width: 7, height: 7)
                    }
                    Image(systemName: selected ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(selected ? Color.white.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("切换到此项目") {
                    store.selectProject(project.id)
                }
                    .disabled(selected)
                if selected {
                    Button("复制项目") {
                        store.duplicateCurrentProject()
                    }
                        .disabled(projectEngine.isActive)
                    Divider()
                    Button("删除项目", role: .destructive) {
                        runRegistry.discard(projectID: project.id)
                        store.deleteCurrentProject()
                    }
                        .disabled(store.projects.count <= 1 || projectEngine.isActive)
                }
            }

            if selected {
                ForEach(AppSection.allCases) { section in
                    sectionButton(section)
                }
            }
        }
    }

    private func sectionButton(_ section: AppSection) -> some View {
        Button {
            store.selectedSection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .frame(width: 18)
                Text(section.title)
                Spacer()
                if section == .memory {
                    Text("\(store.workspace.memories.filter(\.isActive).count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.09), in: Capsule())
                }
            }
            .font(.callout.weight(store.selectedSection == section ? .semibold : .regular))
            .foregroundStyle(store.selectedSection == section ? Color.primary : Color.secondary)
            .padding(.leading, 29)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(
                store.selectedSection == section ? Color(hex: "6FA8DC").opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(alignment: .leading) {
                if store.selectedSection == section {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: "6FA8DC"))
                        .frame(width: 3, height: 19)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cliIsLoggedIn: Bool {
        store.workspace.cliSettings.loginSummary?.localizedCaseInsensitiveContains("logged in") == true
    }

    private var projectFolderName: String {
        URL(fileURLWithPath: store.projectDirectoryDisplayPath(for: store.workspace.id), isDirectory: true)
            .lastPathComponent
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择“\(store.workspace.projectName)”的项目文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let currentPath = store.projectDirectoryDisplayPath(for: store.workspace.id)
        panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.workspace.projectDirectoryPath = url.standardizedFileURL.path
        }
    }

    private func presentRecoveryIfNeeded() {
        guard !currentEngine.isActive,
              recoveryCheckpoint == nil,
              let checkpoint = store.recoverableRunCheckpoint,
              checkpoint.projectID == store.workspace.id else { return }
        recoveryCheckpoint = checkpoint
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch store.selectedSection {
            case .blueprint:
                BlueprintView()
            case .run:
                RunMonitorView()
            case .memory:
                MemoryView()
            case .settings:
                SettingsView()
            }
        }
        .environmentObject(currentEngine)
    }
}

private struct RunRecoveryView: View {
    let checkpoint: RunCheckpoint
    let project: ProjectWorkspace
    let restart: () -> Void
    let resume: () -> Void

    private var completedStepCount: Int {
        Set(checkpoint.session.executions.filter { $0.status == .completed }.map(\.stepID)).count
    }

    private var currentStepTitle: String {
        guard project.steps.indices.contains(checkpoint.nextStepIndex) else { return "完成运行收尾" }
        return "第 \(checkpoint.nextStepIndex + 1) 步 · \(project.steps[checkpoint.nextStepIndex].title)"
    }

    private var partialOutput: String? {
        checkpoint.session.executions.last(where: { $0.status == .running && !$0.output.isEmpty })?.output
    }

    var body: some View {
        ZStack {
            AiGoBackground()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.clockwise.icloud.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Color(hex: "5EEAD4"))
                        .frame(width: 48, height: 48)
                        .background(Color(hex: "0F766E").opacity(0.25), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("发现上次异常中断的运行")
                            .font(.title2.weight(.bold))
                        Text("AiGo 已保存步骤位置、审核回环、人工批准、部分产物和本次运行前的记忆基线。请选择如何处理，窗口不能直接跳过。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    recoveryRow("项目", project.projectName)
                    recoveryRow("恢复位置", currentStepTitle)
                    recoveryRow("已完成", "\(completedStepCount) 个不同步骤 · \(checkpoint.session.executions.count) 次调用记录")
                    recoveryRow("检查点", checkpoint.savedAt.formatted(date: .abbreviated, time: .standard))
                }
                .padding(15)
                .glassPanel(cornerRadius: 14)

                if let partialOutput {
                    DisclosureGroup("查看中断步骤的部分产物（\(partialOutput.count) 字符）") {
                        ScrollView {
                            MarkdownViewer(markdown: String(partialOutput.prefix(5_000)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                        }
                        .frame(maxHeight: 190)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(14)
                    .glassPanel(cornerRadius: 14)
                }

                HStack(spacing: 12) {
                    Button(action: restart) {
                        Label("回滚本次并重新运行", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("移除本次中断运行新增或覆盖的共享记忆，保留运行前知识，然后从第 1 步开始")

                    Button(action: resume) {
                        Label("从中断处继续", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color(hex: "5965E8"))
                }
            }
            .padding(26)
        }
        .frame(width: 640)
        .frame(minHeight: 430)
        .preferredColorScheme(.dark)
    }

    private func recoveryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
