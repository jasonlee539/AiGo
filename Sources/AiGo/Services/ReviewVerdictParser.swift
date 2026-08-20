import Foundation

enum ReviewVerdict: String, Hashable {
    case pass
    case fail
}

enum ReviewVerdictParser {
    static func parse(_ output: String) -> ReviewVerdict? {
        var detected: ReviewVerdict?
        for rawLine in output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = rawLine.uppercased()
                .replacingOccurrences(of: "：", with: ":")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = line.first, "#>-*+ ".contains(first) {
                line.removeFirst()
            }

            if let value = value(after: "AIGO_VERDICT:", in: line)
                ?? value(after: "VERDICT:", in: line) {
                if value.hasPrefix("FAIL") { detected = .fail }
                else if value.hasPrefix("PASS") { detected = .pass }
                continue
            }

            if let value = value(after: "审核结论:", in: line) {
                if value.hasPrefix("不通过") || value.hasPrefix("失败") { detected = .fail }
                else if value.hasPrefix("通过") { detected = .pass }
            }
        }
        return detected
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let prefix = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty || prefix.allSatisfy({ "([{".contains($0) }) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
