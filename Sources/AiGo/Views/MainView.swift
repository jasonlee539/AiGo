import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var engine: OrchestrationEngine

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
        .task(id: store.workspace.id) {
            if store.workspace.cliSettings.cachedModels.isEmpty
                || store.workspace.cliSettings.loginSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                await store.refreshCodexCLI()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "8891FF"), Color(hex: "4F46E5")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("AiGo")
                        .font(.headline.weight(.bold))
                    Text("0.1.1")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(hex: "A5B4FC"))
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
                    .disabled(engine.isActive)
            }

            Spacer()

            Text("\(store.projects.count) 个项目 · \(store.workspace.agents.count)/\(WorkspaceRules.maxAgents) 智能体")
                .font(.caption)
                .foregroundStyle(.secondary)
            ModelBadge(modelID: "Codex CLI", effort: nil)
            RunStatusBadge(phase: engine.session.phase)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(.ultraThinMaterial.opacity(0.52))
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
                    engine.resetMonitor()
                    store.addProject()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(engine.isActive)
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
                Text("每个项目独立保存蓝图、运行、记忆和设置")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 13)
            .padding(10)
        }
        .frame(width: 244)
        .background(Color.black.opacity(0.08))
    }

    private func projectGroup(_ project: ProjectWorkspace) -> some View {
        let selected = project.id == store.workspace.id
        return VStack(spacing: 3) {
            Button {
                if project.id != store.workspace.id { engine.resetMonitor() }
                store.selectProject(project.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "folder.fill" : "folder")
                        .foregroundStyle(selected ? Color(hex: "93A0FF") : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.projectName)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                        Text("\(project.steps.count) 步 · \(project.agents.count) 角色")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(selected ? Color.white.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(engine.isActive && !selected)
            .contextMenu {
                Button("切换到此项目") {
                    engine.resetMonitor()
                    store.selectProject(project.id)
                }
                    .disabled(selected || engine.isActive)
                if selected {
                    Button("复制项目") {
                        engine.resetMonitor()
                        store.duplicateCurrentProject()
                    }
                        .disabled(engine.isActive)
                    Divider()
                    Button("删除项目", role: .destructive) {
                        engine.resetMonitor()
                        store.deleteCurrentProject()
                    }
                        .disabled(store.projects.count <= 1 || engine.isActive)
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
            .foregroundStyle(store.selectedSection == section ? Color.white : Color.secondary)
            .padding(.leading, 29)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(
                store.selectedSection == section ? Color(hex: "6E7BFF").opacity(0.20) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }

    private var cliIsLoggedIn: Bool {
        store.workspace.cliSettings.loginSummary?.localizedCaseInsensitiveContains("logged in") == true
    }

    @ViewBuilder
    private var detail: some View {
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
}
