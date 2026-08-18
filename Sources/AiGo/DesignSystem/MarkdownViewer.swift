import Foundation
import SwiftUI

struct MarkdownViewer: View {
    let markdown: String
    var showsSource = true

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                Text("（空产物）")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }

            if showsSource, !markdown.isEmpty {
                DisclosureGroup("查看原始 Markdown") {
                    ScrollView(.horizontal) {
                        Text(markdown)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 7)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .fontWeight(.bold)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 5 : 2)

        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Color(hex: "93A0FF"))
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 2)
                Text(inline(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color(hex: "A5B4FC"))
                    .frame(minWidth: 22, alignment: .trailing)
                Text(inline(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "8B96FF").opacity(0.7))
                    .frame(width: 3)
                Text(inline(text))
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(Color(hex: "A5B4FC"))
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(11)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07)))

        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell))
                                    .font(rowIndex == 0 ? .callout.weight(.semibold) : .callout)
                                    .textSelection(.enabled)
                                    .frame(minWidth: 110, maxWidth: 240, alignment: .leading)
                                    .padding(8)
                                    .background(rowIndex == 0 ? Color(hex: "6E7BFF").opacity(0.16) : Color.white.opacity(0.035))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

        case .rule:
            Divider().overlay(Color.white.opacity(0.12))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case quote(String)
        case code(String, String)
        case table([[String]])
        case rule
    }

    let id = UUID()
    let kind: Kind
}

private enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph(paragraph.joined(separator: " "))))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .code(language, code.joined(separator: "\n"))))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isTableStart(lines: lines, index: index) {
                flushParagraph()
                var rows: [[String]] = [tableCells(from: lines[index])]
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.contains("|"), !candidate.isEmpty else { break }
                    rows.append(tableCells(from: candidate))
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .table(rows)))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(heading.level, heading.text)))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .quote(text)))
                index += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet(String(trimmed.dropFirst(2)))))
                index += 1
                continue
            }

            if let ordered = orderedItem(from: trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .numbered(ordered.number, ordered.text)))
                index += 1
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = String(line.dropFirst(level))
        guard remainder.hasPrefix(" ") else { return nil }
        return (level, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        guard let separator = line.firstIndex(of: ".") else { return nil }
        let prefix = String(line[..<separator])
        guard let number = Int(prefix), number > 0 else { return nil }
        let remainder = String(line[line.index(after: separator)...])
        guard remainder.hasPrefix(" ") else { return nil }
        return (number, remainder.trimmingCharacters(in: .whitespaces))
    }

    private static func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let cells = tableCells(from: lines[index + 1])
        return !cells.isEmpty && cells.allSatisfy { cell in
            let cleaned = cell.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty && cell.contains("-")
        }
    }

    private static func tableCells(from line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}
