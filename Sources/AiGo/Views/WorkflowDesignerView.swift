import SwiftUI

struct WorkflowDesignerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var designerAgentID: UUID?
    @State private var designRequest = ""
    @State private var proposal: WorkflowProposal?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var confirmsReplacement = false

    var body: some View {
        ZStack {
            AiGoBackground()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                HStack(alignment: .top, spacing: 14) {
                    requestPanel
                        .frame(width: 310)
                    proposalPanel
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
                Divider().overlay(Color.white.opacity(0.08))
                footer
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 720)
        .interactiveDismissDisabled(isGenerating)
        .onAppear {
            if designerAgentID == nil {
                designerAgentID = store.workspace.agents.first(where: { $0.role == .architect })?.id
                    ?? store.workspace.agents.first?.id
            }
            if designRequest.isEmpty { designRequest = store.workspace.projectBrief }
        }
        .confirmationDialog(
            "用草案替换当前 \(store.workspace.steps.count) 个步骤？",
            isPresented: $confirmsReplacement,
            titleVisibility: .visible
        ) {
            Button("替换当前流程", role: .destructive) { apply(replacing: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现有步骤会被草案整体替换；之后仍可在编排蓝图逐项修改。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(Color(hex: "A5B4FC"))
                .frame(width: 42, height: 42)
                .background(Color(hex: "4F46E5").opacity(0.22), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("设计师分配任务")
                    .font(.title3.weight(.bold))
                Text("本机 Codex CLI 只生成流程草案；你可以先修改，再替换或追加到当前项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.workspace.projectName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06), in: Capsule())
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.48))
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("1. 选择流程设计师")
                    .font(.headline)
                Picker("", selection: $designerAgentID) {
                    ForEach(store.workspace.agents) { agent in
                        Label("\(agent.name) · \(agent.roleTitle)", systemImage: agent.role.symbol)
                            .tag(Optional(agent.id))
                    }
                }
                .labelsHidden()

                if let designer = selectedDesigner,
                   let profile = store.workspace.profiles.first(where: { $0.id == designer.profileID }) {
                    ModelBadge(
                        modelID: profile.modelID.isEmpty ? "CLI 默认模型" : profile.modelID,
                        effort: profile.reasoningEffort
                    )
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("2. 写清分配要求")
                    .font(.headline)
                TextEditor(text: $designRequest)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 210)
                    .padding(8)
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                Text("可说明期望产物、必须使用的角色、是否需要代码落盘、审核点和允许回环次数。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                generateProposal()
            } label: {
                HStack {
                    if isGenerating { ProgressView().controlSize(.small) }
                    Label(isGenerating ? "设计师正在编排…" : (proposal == nil ? "生成流程草案" : "重新生成草案"), systemImage: "wand.and.stars")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "5965E8"))
            .disabled(isGenerating || designerAgentID == nil)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(hex: "FB7185"))
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("设计调用始终只读", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: "4ADE80"))
                Text("只有你最终采用的具体步骤，才会按各自权限在正式运行中调用 CLI。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .glassPanel(cornerRadius: 16, emphasized: true)
    }

    @ViewBuilder
    private var proposalPanel: some View {
        if let snapshot = proposal {
            WorkflowProposalEditor(
                proposal: Binding(
                    get: { proposal ?? snapshot },
                    set: { proposal = $0 }
                ),
                agents: store.workspace.agents
            )
        } else {
            VStack(spacing: 12) {
                Spacer()
                EmptyState(
                    symbol: "list.bullet.rectangle.portrait.fill",
                    title: "等待流程草案",
                    detail: "生成后这里会显示完整步骤名称、任务指令、执行角色、文件权限和审核回环。"
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(cornerRadius: 16, emphasized: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isGenerating)
            Spacer()
            if let proposal {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(proposal.steps.count) 步 · \(loopCount(in: proposal.steps)) 个有界回环 · \(writeCount(in: proposal.steps)) 个写入步骤")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let proposalValidationMessage {
                        Text(proposalValidationMessage)
                            .font(.caption2)
                            .foregroundStyle(Color(hex: "FB7185"))
                    }
                }
                Button("追加到当前流程") { apply(replacing: false) }
                    .buttonStyle(.bordered)
                    .disabled(proposalValidationMessage != nil)
                Button("采用并替换当前流程") { confirmsReplacement = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "5965E8"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposalValidationMessage != nil)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial.opacity(0.44))
    }

    private var selectedDesigner: AgentSeat? {
        guard let designerAgentID else { return nil }
        return store.workspace.agents.first(where: { $0.id == designerAgentID })
    }

    private func generateProposal() {
        guard let designerAgentID else { return }
        let projectID = store.workspace.id
        let snapshot = store.workspace
        errorMessage = nil
        isGenerating = true
        Task {
            do {
                let directory = try store.projectDirectory(for: projectID)
                let generated = try await WorkflowDesignService.generate(
                    project: snapshot,
                    designerAgentID: designerAgentID,
                    request: designRequest,
                    workingDirectory: directory
                )
                guard store.workspace.id == projectID else {
                    throw WorkflowDesignerUIError.projectChanged
                }
                proposal = generated
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func apply(replacing: Bool) {
        guard let proposal,
              WorkspaceRules.workflowValidationMessage(
                steps: proposal.steps,
                agents: store.workspace.agents
              ) == nil else { return }
        if replacing { store.replaceWorkflow(with: proposal.steps) }
        else { store.appendWorkflow(proposal.steps) }
        dismiss()
    }

    private func loopCount(in steps: [WorkflowStep]) -> Int {
        steps.filter { $0.reviewReturnStepID != nil }.count
    }

    private func writeCount(in steps: [WorkflowStep]) -> Int {
        steps.filter { $0.executionAccess == .workspaceWrite }.count
    }

    private var proposalValidationMessage: String? {
        guard let proposal else { return nil }
        return WorkspaceRules.workflowValidationMessage(
            steps: proposal.steps,
            agents: store.workspace.agents
        )
    }
}

private struct WorkflowProposalEditor: View {
    @Binding var proposal: WorkflowProposal
    let agents: [AgentSeat]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("3. 检查并修改草案")
                        .font(.headline)
                    Text(proposal.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(proposal.steps.count) 步")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(hex: "A5B4FC"))
            }
            .padding(14)

            if !proposal.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(proposal.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "FBBF24"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(proposal.steps) { item in
                        if let index = proposal.steps.firstIndex(where: { $0.id == item.id }) {
                            WorkflowDraftStepCard(
                                step: $proposal.steps[index],
                                index: index,
                                allSteps: proposal.steps,
                                agents: agents,
                                moveUp: { move(id: item.id, offset: -1) },
                                moveDown: { move(id: item.id, offset: 1) },
                                delete: { delete(id: item.id) }
                            )
                        }
                    }

                    DisclosureGroup("查看设计师原始 JSON") {
                        Text(proposal.rawOutput)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 7)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
                }
                .padding(12)
            }
        }
        .glassPanel(cornerRadius: 16, emphasized: true)
    }

    private func move(id: UUID, offset: Int) {
        guard let source = proposal.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard proposal.steps.indices.contains(destination) else { return }
        proposal.steps.swapAt(source, destination)
        normalizeLoops()
    }

    private func delete(id: UUID) {
        guard proposal.steps.count > 1 else { return }
        proposal.steps.removeAll { $0.id == id }
        for index in proposal.steps.indices where proposal.steps[index].reviewReturnStepID == id {
            proposal.steps[index].reviewReturnStepID = nil
        }
        normalizeLoops()
    }

    private func normalizeLoops() {
        for index in proposal.steps.indices {
            guard let target = proposal.steps[index].reviewReturnStepID,
                  let targetIndex = proposal.steps.firstIndex(where: { $0.id == target }),
                  targetIndex < index else {
                proposal.steps[index].reviewReturnStepID = nil
                continue
            }
        }
    }
}

private struct WorkflowDraftStepCard: View {
    @Binding var step: WorkflowStep
    let index: Int
    let allSteps: [WorkflowStep]
    let agents: [AgentSeat]
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                labeled("步骤名称") {
                    TextField("必须填写步骤名称", text: $step.title)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("任务指令") {
                    TextEditor(text: $step.instruction)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 112)
                        .padding(7)
                        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(alignment: .top, spacing: 12) {
                    labeled("执行智能体") {
                        Picker("", selection: $step.agentID) {
                            ForEach(agents) { agent in
                                Text("\(agent.name) · \(agent.roleTitle)").tag(agent.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: step.agentID) { _, newValue in
                            applyRoleDefaults(for: newValue)
                        }
                    }
                    labeled("输入范围") {
                        Picker("", selection: $step.inputMode) {
                            ForEach(StepInputMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .labelsHidden()
                    }
                }
                labeled("执行权限") {
                    Picker("", selection: $step.executionAccess) {
                        ForEach(StepExecutionAccess.allCases) { access in
                            Text(access.title).tag(access)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("执行前人工批准", isOn: $step.requiresApproval)
                labeled("审核失败回环") {
                    Picker("", selection: $step.reviewReturnStepID) {
                        Text("不回环；FAIL 时停止").tag(nil as UUID?)
                        ForEach(Array(allSteps.enumerated()), id: \.element.id) { candidateIndex, candidate in
                            if candidateIndex < index {
                                Text("回到步骤 \(candidateIndex + 1)：\(candidate.title)").tag(Optional(candidate.id))
                            }
                        }
                    }
                    .labelsHidden()
                }
                if step.reviewReturnStepID != nil {
                    Stepper("最多回环 \(step.maxReviewRetries) 次", value: $step.maxReviewRetries, in: 1...5)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 9) {
                Text("\(index + 1)")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: "6E7BFF").opacity(0.18), in: Circle())
                    .foregroundStyle(Color(hex: "A5B4FC"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title.isEmpty ? "未填写步骤名称" : step.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(agentName) · \(step.executionAccess.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if step.reviewReturnStepID != nil {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(Color(hex: "FB7185"))
                }
                if step.executionAccess == .workspaceWrite {
                    Image(systemName: "pencil.and.outline")
                        .foregroundStyle(Color(hex: "FBBF24"))
                }
                Button(action: moveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                Button(action: moveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == allSteps.count - 1)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(allSteps.count <= 1)
            }
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07)))
    }

    private var agentName: String {
        agents.first(where: { $0.id == step.agentID })?.name ?? "未分配"
    }

    private func applyRoleDefaults(for agentID: UUID) {
        guard let role = agents.first(where: { $0.id == agentID })?.role else { return }
        if role == .coder {
            step.executionAccess = .workspaceWrite
            if !step.instruction.contains("真实文件") {
                step.instruction += "\n\n必须检查并修改当前项目目录中的真实文件，运行相关测试或构建；不得只返回伪代码。"
            }
        } else if role == .reviewer {
            step.executionAccess = .readOnly
            if !step.instruction.contains("AIGO_VERDICT") {
                step.instruction += "\n\n必须单独输出 AIGO_VERDICT: PASS 或 AIGO_VERDICT: FAIL。"
            }
        } else {
            step.executionAccess = .workspaceWrite
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum WorkflowDesignerUIError: LocalizedError {
    case projectChanged
    var errorDescription: String? { "生成期间项目已切换，草案未应用。" }
}
