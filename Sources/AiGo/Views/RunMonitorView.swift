import SwiftUI

struct RunMonitorView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var engine: OrchestrationEngine

    var body: some View {
        VStack(spacing: 12) {
            runToolbar
            HStack(alignment: .top, spacing: 12) {
                executionColumn
                    .frame(maxWidth: .infinity)
                eventColumn
                    .frame(width: 320)
            }
        }
        .padding(14)
    }

    private var runToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("运行监控 · \(store.workspace.projectName)")
                        .font(.title3.weight(.bold))
                    RunStatusBadge(phase: engine.session.phase)
                }
                Text("按编号依次调用本机 Codex CLI；门控、回退、活动和自动记忆均进入当前项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if engine.session.phase == .awaitingApproval {
                Button {
                    engine.approveAndContinue()
                } label: {
                    Label("批准并调用 CLI", systemImage: "hand.thumbsup.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "D99016"))
            }

            if engine.isActive {
                Button(role: .destructive) {
                    engine.cancel()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                if engine.session.phase != .idle {
                    Button("清空面板") { engine.resetMonitor() }
                        .buttonStyle(.bordered)
                }
                Button {
                    startRun()
                } label: {
                    Label("运行完整流程", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "5965E8"))
            }
        }
        .padding(15)
        .glassPanel(cornerRadius: 16, emphasized: true)
    }

    private var executionColumn: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("步骤产物")
                        .font(.headline)
                    Text("默认折叠；展开后按 Markdown 阅读，并自动提炼给后续角色")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let completed = engine.session.executions.filter { $0.status == .completed }.count
                Text("\(completed)/\(store.workspace.steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            ProgressView(
                value: Double(engine.session.executions.filter { $0.status == .completed }.count),
                total: Double(max(1, store.workspace.steps.count))
            )
            .tint(Color(hex: "6E7BFF"))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.08))

            if engine.session.executions.isEmpty {
                Spacer()
                EmptyState(
                    symbol: "terminal.fill",
                    title: "尚未调用 Codex CLI",
                    detail: "点击“运行完整流程”，AiGo 会使用本机 CLI 登录和当前项目的角色模型配置。"
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(engine.session.executions) { execution in
                            StepExecutionDisclosureCard(execution: execution)
                        }

                        if !engine.currentContextPreview.isEmpty {
                            DisclosureGroup("当前步骤实际提示上下文") {
                                Text(engine.currentContextPreview)
                                    .textSelection(.enabled)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                            .padding(13)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .glassPanel(emphasized: true)
    }

    private var eventColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("事件时间线")
                    .font(.headline)
                Spacer()
                Text("\(engine.session.events.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider().overlay(Color.white.opacity(0.08))

            if engine.session.events.isEmpty {
                Spacer()
                EmptyState(symbol: "clock", title: "暂无事件", detail: "启动后记录 CLI 线程、门控、步骤、回退和错误。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(engine.session.events.reversed()) { event in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(eventColor(event.kind))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.message)
                                        .font(.caption)
                                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("项目运行历史", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(store.workspace.runHistory.count)/20")
                }
                .font(.caption.weight(.semibold))
                if let latest = store.workspace.runHistory.first {
                    Text("最近：\(latest.phase.title) · \(latest.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "进行中")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前项目暂无归档运行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            if let error = engine.session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(hex: "FB7185"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "7F1D1D").opacity(0.24))
            }
        }
        .glassPanel(emphasized: true)
    }

    private func startRun() {
        let projectID = store.workspace.id
        do {
            let directory = try store.projectDirectory(for: projectID)
            engine.start(
                workspace: store.workspace,
                workingDirectory: directory,
                onMemory: { memory in
                    store.integrateAutomaticMemory(memory, projectID: projectID)
                },
                onFinish: { session in
                    store.archive(session)
                }
            )
        } catch {
            store.persistenceMessage = "无法建立项目工作目录：\(error.localizedDescription)"
        }
    }

    private func eventColor(_ kind: String) -> Color {
        switch kind {
        case "success": return Color(hex: "22C55E")
        case "error": return Color(hex: "F43F5E")
        case "warning", "approval": return Color(hex: "F59E0B")
        case "retry": return Color(hex: "A78BFA")
        case "activity", "cli": return Color(hex: "38BDF8")
        default: return Color(hex: "93A0FF")
        }
    }
}

private struct StepExecutionDisclosureCard: View {
    let execution: StepExecution
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let threadID = execution.cliThreadID {
                    Text("CLI thread \(threadID)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                if let error = execution.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color(hex: "FB7185"))
                }

                if execution.output.isEmpty && execution.status == .running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待本机 Codex CLI 返回结果…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownViewer(markdown: execution.output)
                        .padding(13)
                        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                }

                if let activities = execution.activityLog, !activities.isEmpty {
                    DisclosureGroup("CLI 活动（\(activities.count)）") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(activities.enumerated()), id: \.offset) { _, activity in
                                Text("• \(activity)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                    }
                    .font(.caption)
                }

                if execution.status == .completed {
                    Label("关键内容已拆分、去重并自动写入共享记忆", systemImage: "brain.head.profile.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(hex: "4ADE80"))
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 9) {
                Text("\(execution.stepNumber)")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(statusColor.opacity(0.16), in: Circle())
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(execution.stepTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(execution.agentName) · 第 \(execution.attempt) 次")
                        if !execution.output.isEmpty {
                            Text("·")
                            Text("\(execution.output.count) 字符")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ModelBadge(
                    modelID: execution.modelID ?? "CLI 默认模型",
                    effort: execution.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
                )
                if let input = execution.inputTokens, let output = execution.outputTokens {
                    Text("\(input) → \(output) tokens")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .padding(13)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(statusColor.opacity(0.20))
        )
    }

    private var statusColor: Color {
        switch execution.status {
        case .queued: return .secondary
        case .running: return Color(hex: "38BDF8")
        case .completed: return Color(hex: "22C55E")
        case .failed: return Color(hex: "F43F5E")
        case .cancelled: return Color(hex: "94A3B8")
        }
    }
}
