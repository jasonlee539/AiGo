import Foundation

struct CodexCLIInspection: Hashable {
    var version: String
    var loginSummary: String
    var models: [CLIModelDescriptor]
}

struct CodexCLIUsage: Hashable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
}

struct CodexCLICompletion: Hashable {
    var output: String
    var threadID: String?
    var activities: [String]
    var usage: CodexCLIUsage?
}

enum CodexCLIStreamEvent: Hashable {
    case threadStarted(String)
    case agentMessage(String)
    case activity(String)
    case completed(CodexCLIUsage)
    case failed(String)
}

enum CodexCLIError: LocalizedError {
    case executableNotFound(String)
    case launch(String)
    case commandFailed(Int32, String)
    case reported(String)
    case invalidCatalog
    case noAgentMessage

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "找不到可执行的 Codex CLI：\(path)"
        case .launch(let detail): return "无法启动 Codex CLI：\(detail)"
        case .commandFailed(let status, let detail): return "Codex CLI 退出码 \(status)：\(detail)"
        case .reported(let detail): return "Codex CLI 报告失败：\(detail)"
        case .invalidCatalog: return "Codex CLI 返回了无法解析的模型目录。"
        case .noAgentMessage: return "Codex CLI 已结束，但没有返回智能体正文。"
        }
    }
}

enum CodexCLIService {
    static func inspect(executablePath: String) async throws -> CodexCLIInspection {
        let versionOutput = try await capture(executablePath: executablePath, arguments: ["--version"])
        let loginOutput = try await capture(executablePath: executablePath, arguments: ["login", "status"])
        let catalogOutput = try await capture(executablePath: executablePath, arguments: ["debug", "models"])
        let models = try parseCatalog(catalogOutput.stdout)
        return CodexCLIInspection(
            version: versionOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            loginSummary: meaningfulOutput(stdout: loginOutput.stdout, stderr: loginOutput.stderr),
            models: models
        )
    }

    static func stream(
        executablePath: String,
        workingDirectory: URL,
        modelID: String,
        reasoningEffort: ReasoningEffort,
        executionAccess: StepExecutionAccess = .workspaceWrite,
        prompt: String
    ) -> AsyncThrowingStream<CodexCLIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = configuredProcess(executablePath: executablePath)
            let arguments = executionArguments(
                workingDirectory: workingDirectory,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                executionAccess: executionAccess
            )
            process.arguments = commandArguments(executablePath: executablePath, arguments: arguments)
            process.currentDirectoryURL = workingDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            let worker = Task.detached {
                do {
                    try process.run()
                    let stderrTask = Task.detached {
                        stderr.fileHandleForReading.readDataToEndOfFile()
                    }
                    if let data = prompt.data(using: .utf8) {
                        try stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                    try stdin.fileHandleForWriting.close()

                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if let event = parseJSONLine(line) { continuation.yield(event) }
                    }
                    process.waitUntilExit()
                    let errorData = await stderrTask.value
                    if process.terminationStatus != 0 {
                        let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
                        throw CodexCLIError.commandFailed(process.terminationStatus, detail)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                worker.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    static func complete(
        executablePath: String,
        workingDirectory: URL,
        modelID: String,
        reasoningEffort: ReasoningEffort,
        executionAccess: StepExecutionAccess = .workspaceWrite,
        prompt: String
    ) async throws -> CodexCLICompletion {
        var completion = CodexCLICompletion(output: "", threadID: nil, activities: [], usage: nil)
        for try await event in stream(
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            executionAccess: executionAccess,
            prompt: prompt
        ) {
            switch event {
            case .threadStarted(let threadID):
                completion.threadID = threadID
            case .agentMessage(let message):
                if !completion.output.isEmpty { completion.output += "\n\n" }
                completion.output += message
            case .activity(let activity):
                completion.activities.append(activity)
            case .completed(let usage):
                completion.usage = usage
            case .failed(let message):
                throw CodexCLIError.reported(message)
            }
        }
        guard !completion.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexCLIError.noAgentMessage
        }
        return completion
    }

    static func executionArguments(
        workingDirectory: URL,
        modelID: String,
        reasoningEffort: ReasoningEffort,
        executionAccess: StepExecutionAccess
    ) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--ephemeral",
            "--sandbox", executionAccess.rawValue,
            "--skip-git-repo-check",
            "--color", "never",
            "-C", workingDirectory.path
        ]
        if !modelID.isEmpty { arguments += ["--model", modelID] }
        arguments += ["--config", "model_reasoning_effort=\"\(reasoningEffort.rawValue)\"", "-"]
        return arguments
    }

    static func parseJSONLine(_ line: String) -> CodexCLIStreamEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "thread.started":
            return (object["thread_id"] as? String).map(CodexCLIStreamEvent.threadStarted)
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String else { return nil }
            if itemType == "agent_message", type == "item.completed", let text = item["text"] as? String {
                return .agentMessage(text)
            }
            if itemType == "command_execution", let command = item["command"] as? String {
                return .activity("命令：\(String(command.prefix(180)))")
            }
            if itemType == "web_search", let query = item["query"] as? String {
                return .activity("检索：\(String(query.prefix(180)))")
            }
            if itemType == "file_change" { return .activity("CLI 文件变更：\(String((item["changes"] as? String ?? "项目文件已更新").prefix(180)))") }
            return nil
        case "turn.completed":
            let usage = object["usage"] as? [String: Any]
            return .completed(
                CodexCLIUsage(
                    inputTokens: integer(usage?["input_tokens"]),
                    cachedInputTokens: integer(usage?["cached_input_tokens"]),
                    outputTokens: integer(usage?["output_tokens"])
                )
            )
        case "turn.failed", "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? object["message"] as? String ?? "Codex CLI 运行失败。"
            return .failed(message)
        default:
            return nil
        }
    }

    private struct ProcessOutput {
        var stdout: String
        var stderr: String
    }

    private struct Catalog: Decodable {
        var models: [RawModel]
    }

    private struct RawModel: Decodable {
        struct Level: Decodable { var effort: String }
        var slug: String
        var displayName: String
        var defaultReasoningLevel: String
        var supportedReasoningLevels: [Level]
        var visibility: String
        var priority: Int

        enum CodingKeys: String, CodingKey {
            case slug, visibility, priority
            case displayName = "display_name"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    static func parseCatalog(_ text: String) throws -> [CLIModelDescriptor] {
        guard let data = text.data(using: .utf8), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw CodexCLIError.invalidCatalog
        }
        let visible = catalog.models.filter { $0.visibility == "list" }.sorted { $0.priority < $1.priority }
        let defaultPriority = visible.map(\.priority).min()
        return visible.map { model in
            let supported = model.supportedReasoningLevels.compactMap { ReasoningEffort(rawValue: $0.effort) }
            return CLIModelDescriptor(
                modelID: model.slug,
                displayName: model.displayName,
                defaultReasoningEffort: ReasoningEffort(rawValue: model.defaultReasoningLevel) ?? supported.first ?? .medium,
                supportedReasoningEfforts: supported.isEmpty ? [.low, .medium, .high] : supported,
                isDefault: model.priority == defaultPriority,
                priority: model.priority
            )
        }
    }

    private static func capture(executablePath: String, arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = configuredProcess(executablePath: executablePath)
                process.arguments = commandArguments(executablePath: executablePath, arguments: arguments)
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    let group = DispatchGroup()
                    var outputData = Data()
                    var errorData = Data()
                    group.enter()
                    DispatchQueue.global().async {
                        outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: CodexCLIError.commandFailed(process.terminationStatus, error))
                        return
                    }
                    continuation.resume(returning: ProcessOutput(stdout: output, stderr: error))
                } catch {
                    continuation.resume(throwing: CodexCLIError.launch(error.localizedDescription))
                }
            }
        }
    }

    private static func configuredProcess(executablePath: String) -> Process {
        let process = Process()
        if executablePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executablePath)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        }
        var environment = ProcessInfo.processInfo.environment
        let originalPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + originalPath
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        return process
    }

    private static func commandArguments(executablePath: String, arguments: [String]) -> [String] {
        executablePath.hasPrefix("/") ? arguments : [executablePath] + arguments
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func meaningfulOutput(stdout: String, stderr: String) -> String {
        let lines = (stdout + "\n" + stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
        return lines.joined(separator: " · ")
    }
}
