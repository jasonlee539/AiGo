import SwiftUI

struct BlueprintView: View {
    @EnvironmentObject private var engine: OrchestrationEngine

    var body: some View {
        HStack(spacing: 12) {
            AgentRosterView()
                .frame(width: 250)
            WorkflowCanvasView()
                .frame(maxWidth: .infinity)
            BlueprintInspectorView()
                .frame(width: 318)
        }
        .padding(14)
        .disabled(engine.isActive)
    }
}

private struct AgentRosterView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能体团队")
                        .font(.headline)
                    Text("最多 8 个角色，可重复执行步骤")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _ = store.addAgent()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.workspace.agents.count >= WorkspaceRules.maxAgents)
                .help(store.workspace.agents.count >= WorkspaceRules.maxAgents ? "已达到 8 个智能体上限" : "新增智能体")
            }
            .padding(14)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.workspace.agents) { agent in
                        agentCard(agent)
                    }
                }
                .padding(10)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Label("\(store.workspace.agents.count) 个席位", systemImage: "person.3.fill")
                Spacer()
                Text("上限 \(WorkspaceRules.maxAgents)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .glassPanel(emphasized: true)
    }

    private func agentCard(_ agent: AgentSeat) -> some View {
        let selected = store.selectedAgentID == agent.id && store.selectedStepID == nil
        let profile = store.workspace.profiles.first { $0.id == agent.profileID }

        return Button {
            store.selectedAgentID = agent.id
            store.selectedStepID = nil
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hex: agent.colorHex).opacity(0.20))
                    Image(systemName: agent.role.symbol)
                        .foregroundStyle(Color(hex: agent.colorHex))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(agent.role.title) · \(profileModelLabel(profile)) · \(profile?.reasoningEffort.title ?? "未配置")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                let usage = store.workspace.steps.filter { $0.agentID == agent.id }.count
                Text("\(usage)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .padding(9)
            .background(
                selected ? Color(hex: agent.colorHex).opacity(0.16) : Color.white.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color(hex: agent.colorHex).opacity(0.48) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除智能体", role: .destructive) {
                store.deleteAgent(id: agent.id)
            }
            .disabled(store.workspace.agents.count <= 1)
        }
    }

    private func profileModelLabel(_ profile: CodexProfile?) -> String {
        guard let profile else { return "未配置" }
        return profile.modelID.isEmpty ? "CLI 默认" : profile.modelID
    }
}

private struct WorkflowCanvasView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 12) {
            projectBrief
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("顺序流程")
                            .font(.headline)
                        Text("步骤不限；默认按 1 → 2 → 3 顺序运行")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.addStep(after: store.selectedStepID)
                    } label: {
                        Label("添加步骤", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(hex: "5965E8"))
                }
                .padding(14)

                Divider().overlay(Color.white.opacity(0.08))

                if store.workspace.steps.isEmpty {
                    Spacer()
                    EmptyState(
                        symbol: "list.number",
                        title: "还没有流程步骤",
                        detail: "添加步骤后，为它选择执行智能体；同一智能体可以出现在多个位置。"
                    )
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.workspace.steps.enumerated()), id: \.element.id) { index, step in
                                stepCard(step, index: index)
                                if index < store.workspace.steps.count - 1 {
                                    Image(systemName: "arrow.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(hex: "8B96FF").opacity(0.72))
                                        .frame(height: 24)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .glassPanel(emphasized: true)
        }
    }

    private var projectBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("项目目标与约束", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("所有步骤的公共输入")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $store.workspace.projectBrief)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 66, maxHeight: 90)
                .padding(7)
                .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(13)
        .glassPanel(cornerRadius: 15)
    }

    private func stepCard(_ step: WorkflowStep, index: Int) -> some View {
        let agent = store.workspace.agents.first { $0.id == step.agentID }
        let selected = store.selectedStepID == step.id
        let tint = Color(hex: agent?.colorHex ?? "6E7BFF")

        return Button {
            store.selectedStepID = step.id
            store.selectedAgentID = nil
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.headline.monospacedDigit().weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.19), in: Circle())
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(step.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if step.requiresApproval {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption2)
                                .foregroundStyle(Color(hex: "F59E0B"))
                                .help("执行前需要人工批准")
                        }
                        if step.reviewReturnStepID != nil {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color(hex: "F43F5E"))
                                .help("审核失败时回退")
                        }
                    }
                    HStack(spacing: 5) {
                        Image(systemName: agent?.role.symbol ?? "person.fill")
                        Text(agent?.name ?? "未分配")
                        Text("·")
                        Text(step.inputMode.title)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 3) {
                    Button { store.moveStep(id: step.id, offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button { store.moveStep(id: step.id, offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == store.workspace.steps.count - 1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(
                selected ? tint.opacity(0.14) : Color.white.opacity(0.026),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? tint.opacity(0.5) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("在后面插入步骤") { store.addStep(after: step.id) }
            Divider()
            Button("删除步骤", role: .destructive) { store.deleteStep(id: step.id) }
        }
    }
}

private struct BlueprintInspectorView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("属性检查器")
                    .font(.headline)
                Spacer()
            }
            .padding(14)
            Divider().overlay(Color.white.opacity(0.08))

            if let stepID = store.selectedStepID,
               let index = store.workspace.steps.firstIndex(where: { $0.id == stepID }) {
                StepInspector(
                    step: $store.workspace.steps[index],
                    stepIndex: index,
                    agents: store.workspace.agents,
                    steps: store.workspace.steps,
                    onDelete: { store.deleteStep(id: stepID) }
                )
                .id(stepID)
            } else if let agentID = store.selectedAgentID,
                      let index = store.workspace.agents.firstIndex(where: { $0.id == agentID }) {
                AgentInspector(
                    agent: $store.workspace.agents[index],
                    profiles: store.workspace.profiles,
                    canDelete: store.workspace.agents.count > 1,
                    onDelete: { store.deleteAgent(id: agentID) }
                )
            } else {
                Spacer()
                EmptyState(
                    symbol: "cursorarrow.click.2",
                    title: "选择一个对象",
                    detail: "点击左侧智能体或中间流程步骤，在这里编辑详细配置。"
                )
                Spacer()
            }
        }
        .glassPanel(emphasized: true)
    }
}

private struct AgentInspector: View {
    @Binding var agent: AgentSeat
    let profiles: [CodexProfile]
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Label("智能体角色", systemImage: agent.role.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: agent.colorHex))

                field("显示名称") {
                    TextField("智能体名称", text: $agent.name)
                        .textFieldStyle(.roundedBorder)
                }

                field("角色类型") {
                    Picker("", selection: $agent.role) {
                        ForEach(AgentRole.allCases) { role in
                            Label(role.title, systemImage: role.symbol).tag(role)
                        }
                    }
                    .labelsHidden()
                }

                field("Codex 配置") {
                    Picker("", selection: $agent.profileID) {
                        ForEach(profiles) { profile in
                            Text("\(profile.name) · \(profile.modelID.isEmpty ? "CLI 默认" : profile.modelID) · \(profile.reasoningEffort.title)").tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    let selectedProfile = profiles.first { $0.id == agent.profileID }
                    ModelBadge(
                        modelID: selectedProfile?.modelID ?? "",
                        effort: selectedProfile?.reasoningEffort
                    )
                }

                field("角色指令") {
                    TextEditor(text: $agent.instruction)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(7)
                        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    Button("恢复该角色的默认指令") {
                        agent.instruction = agent.role.defaultInstruction
                        agent.colorHex = agent.role.tintHex
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }

                Divider()
                Button("删除这个智能体", role: .destructive, action: onDelete)
                    .disabled(!canDelete)
            }
            .padding(14)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct StepInspector: View {
    @Binding var step: WorkflowStep
    let stepIndex: Int
    let agents: [AgentSeat]
    let steps: [WorkflowStep]
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("步骤 \(stepIndex + 1)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("ID \(step.id.uuidString.prefix(6))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                field("步骤名称") {
                    TextField("步骤名称", text: $step.title)
                        .textFieldStyle(.roundedBorder)
                }

                field("执行智能体") {
                    Picker("", selection: $step.agentID) {
                        ForEach(agents) { agent in
                            Label(agent.name, systemImage: agent.role.symbol).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                }

                field("输入范围") {
                    Picker("", selection: $step.inputMode) {
                        ForEach(StepInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                field("任务指令") {
                    StableTaskInstructionEditor(text: $step.instruction)
                }

                Toggle(isOn: $step.requiresApproval) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("执行前人工批准")
                        Text("运行到此处时暂停，等待你确认")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                field("审核失败时回退") {
                    Picker("", selection: $step.reviewReturnStepID) {
                        Text("不自动回退").tag(nil as UUID?)
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, candidate in
                            if candidate.id != step.id && index < stepIndex {
                                Text("步骤 \(index + 1)：\(candidate.title)").tag(Optional(candidate.id))
                            }
                        }
                    }
                    .labelsHidden()
                    Text("当输出含 VERDICT: FAIL 时，最多自动回退重做一次。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Button("删除这个步骤", role: .destructive, action: onDelete)
            }
            .padding(14)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct StableTaskInstructionEditor: View {
    @Binding private var text: String
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(text: Binding<String>) {
        _text = text
        _draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("描述输入、工作要求、输出格式和完成判据。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .focused($isFocused)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
        }
        .padding(7)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isFocused ? Color(hex: "8B96FF").opacity(0.55) : Color.white.opacity(0.05))
        )
        .onChange(of: draft) { _, newValue in
            if text != newValue { text = newValue }
        }
    }
}
