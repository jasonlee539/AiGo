import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var scope: MemoryScope = .knowledge
    @State private var selectedKind: MemoryKind?

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(spacing: 12) {
                kindRail
                    .frame(width: 182)
                memoryList
                    .frame(width: 330)
                memoryDetail
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .onChange(of: selectedKind) { _, _ in selectFirstVisibleMemory() }
        .onChange(of: scope) { _, _ in
            selectedKind = nil
            selectFirstVisibleMemory()
        }
        .onChange(of: store.workspace.id) { _, _ in
            scope = .knowledge
            selectedKind = nil
            selectFirstVisibleMemory()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "brain.head.profile.fill")
                .font(.title2)
                .foregroundStyle(Color(hex: "A78BFA"))
                .frame(width: 42, height: 42)
                .background(Color(hex: "6D28D9").opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("自动共享记忆")
                    .font(.title3.weight(.bold))
                Text("步骤产物会拆成事实、决策、约束、风险和后续行动；同一主题更新原记录，不再无限叠加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("记忆视图", selection: $scope) {
                ForEach(MemoryScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 218)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(knowledgeCount) 条有效知识")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("每次最多注入 10 条 / 6,000 字符")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .glassPanel(cornerRadius: 16, emphasized: true)
    }

    private var kindRail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(scope == .knowledge ? "知识类型" : "审计类型")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 11)
                .padding(.top, 12)

            kindButton(nil, title: scope == .knowledge ? "全部知识" : "全部日志", symbol: "tray.full.fill", count: scopedMemories.count)
            ForEach(availableKinds) { kind in
                kindButton(
                    kind,
                    title: kind.title,
                    symbol: kind.symbol,
                    count: scopedMemories.filter { $0.kind == kind }.count
                )
            }
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label(scope == .knowledge ? "相关性选取" : "不进入提示词", systemImage: scope == .knowledge ? "scope" : "eye.slash.fill")
                    .font(.caption.weight(.semibold))
                Text(scope == .knowledge
                     ? "后续步骤只获取与当前任务最相关的知识；主脉络优先，旧内容自动压缩。"
                     : "修改日志与运行摘要只用于追踪，不会占用模型上下文。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(11)
        }
        .glassPanel(emphasized: true)
    }

    private func kindButton(_ kind: MemoryKind?, title: String, symbol: String, count: Int) -> some View {
        let selected = selectedKind == kind
        return Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color(hex: "6E7BFF").opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
    }

    private var memoryList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedKind?.title ?? (scope == .knowledge ? "全部有效知识" : "全部审计日志"))
                        .font(.headline)
                    Text("按最后更新时间排列")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(filteredMemories.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider().overlay(Color.white.opacity(0.08))

            if filteredMemories.isEmpty {
                Spacer()
                EmptyState(
                    symbol: scope == .knowledge ? "brain" : "doc.text.magnifyingglass",
                    title: scope == .knowledge ? "暂无此类知识" : "暂无此类日志",
                    detail: "修改蓝图或运行流程后，AiGo 会自动整理。"
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredMemories) { memory in
                            memoryRow(memory)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .glassPanel(emphasized: true)
    }

    private func memoryRow(_ memory: MemoryRecord) -> some View {
        let selected = store.selectedMemoryID == memory.id
        return Button {
            store.selectedMemoryID = memory.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: memory.kind.symbol)
                    .foregroundStyle(kindColor(memory.kind))
                    .frame(width: 27, height: 27)
                    .background(kindColor(memory.kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(memory.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if memory.revision > 1 {
                            Text("r\(memory.revision)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(Color(hex: "A5B4FC"))
                        }
                    }
                    Text(memory.content.isEmpty ? "空内容" : memory.content)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 5) {
                        Text(memory.source)
                        Text("·")
                        Text(memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? Color(hex: "6E7BFF").opacity(0.16) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? Color(hex: "8B96FF").opacity(0.42) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var memoryDetail: some View {
        if let memory = selectedMemory {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Label(memory.kind.title, systemImage: memory.kind.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(kindColor(memory.kind))
                            Text(memory.kind.participatesInPrompt ? "有效知识" : "审计记录")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((memory.kind.participatesInPrompt ? Color(hex: "22C55E") : Color(hex: "64748B")).opacity(0.14), in: Capsule())
                                .foregroundStyle(memory.kind.participatesInPrompt ? Color(hex: "4ADE80") : .secondary)
                        }
                        Text(memory.title)
                            .font(.title3.weight(.bold))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("修订 \(memory.revision)")
                        Text("更新于 \(memory.updatedAt.formatted(date: .long, time: .shortened))")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(16)

                Divider().overlay(Color.white.opacity(0.08))

                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(spacing: 18) {
                            Label("来源：\(memory.source)", systemImage: "link")
                            Label(
                                memory.kind.participatesInPrompt ? "按相关性参与后续上下文" : "仅供审计，不注入模型",
                                systemImage: memory.kind.participatesInPrompt ? "scope" : "eye.slash.fill"
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        MarkdownViewer(markdown: memory.content, showsSource: false)
                            .padding(15)
                            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                        if memory.stableKey != nil || memory.relatedStepID != nil || memory.relatedRunID != nil {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("追踪信息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if let stableKey = memory.stableKey {
                                    Text("稳定键：\(stableKey)")
                                }
                                if let stepID = memory.relatedStepID {
                                    Text("步骤 ID：\(stepID.uuidString)")
                                }
                                if let runID = memory.relatedRunID {
                                    Text("运行 ID：\(runID.uuidString)")
                                }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                }
            }
            .glassPanel(emphasized: true)
        } else {
            VStack {
                Spacer()
                EmptyState(
                    symbol: scope == .knowledge ? "scope" : "doc.text.magnifyingglass",
                    title: scope == .knowledge ? "共享由系统自动维护" : "审计记录与模型上下文隔离",
                    detail: scope == .knowledge
                        ? "选择一条知识查看来源、稳定键和修订；同一主题只更新，不重复追加。"
                        : "这里保留配置修改和运行摘要，便于追踪但不增加后续提示词。"
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(emphasized: true)
        }
    }

    private var availableKinds: [MemoryKind] {
        MemoryKind.allCases.filter { scope == .knowledge ? $0.participatesInPrompt : $0.isAudit }
    }

    private var scopedMemories: [MemoryRecord] {
        store.workspace.memories.filter { memory in
            memory.isActive && (scope == .knowledge ? memory.kind.participatesInPrompt : memory.kind.isAudit)
        }
    }

    private var filteredMemories: [MemoryRecord] {
        scopedMemories
            .filter { selectedKind == nil || $0.kind == selectedKind }
            .sorted { lhs, rhs in
                if lhs.kind == .mainline, rhs.kind != .mainline { return true }
                if rhs.kind == .mainline, lhs.kind != .mainline { return false }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var selectedMemory: MemoryRecord? {
        guard let id = store.selectedMemoryID else { return filteredMemories.first }
        return filteredMemories.first(where: { $0.id == id }) ?? filteredMemories.first
    }

    private var knowledgeCount: Int {
        store.workspace.memories.filter { $0.isActive && $0.kind.participatesInPrompt }.count
    }

    private func selectFirstVisibleMemory() {
        store.selectedMemoryID = filteredMemories.first?.id
    }

    private func kindColor(_ kind: MemoryKind) -> Color {
        switch kind {
        case .mainline: return Color(hex: "93A0FF")
        case .finding: return Color(hex: "38BDF8")
        case .decision: return Color(hex: "4ADE80")
        case .constraint: return Color(hex: "F59E0B")
        case .risk: return Color(hex: "FB7185")
        case .nextAction: return Color(hex: "2DD4BF")
        case .stepInsight: return Color(hex: "A78BFA")
        case .changeLog: return Color(hex: "64748B")
        case .runSummary: return Color(hex: "FBBF24")
        case .migrated: return Color(hex: "94A3B8")
        }
    }
}

private enum MemoryScope: String, CaseIterable, Identifiable {
    case knowledge
    case audit

    var id: String { rawValue }
    var title: String { self == .knowledge ? "有效知识" : "审计日志" }
}
