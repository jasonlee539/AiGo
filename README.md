# AiGo 0.1.1

AiGo 是一个本地优先的 macOS 科研智能体编排原型。它把每个科研项目拆成角色和编号步骤，让最多 8 个智能体按用户安排的 `1 → 2 → 3 → …` 顺序协作。

0.1.1 不使用 OpenAI API Key，不包含离线演示，也没有固定模型。所有模型调用都通过用户已经登录的本机 Codex CLI 完成。

## 怎么试用

1. 先在终端确认 Codex CLI 可用且已登录：

   ```bash
   codex --version
   codex login status
   ```

2. 打开 `Dist/AiGo.app`，或挂载 `Dist/AiGo-0.1.1-AppleSilicon.dmg` 后把 AiGo 拖入“应用程序”。
3. 进入当前项目的“Codex 设置”，选择或输入这个项目的实际文件夹，再点击“检测并刷新”。AiGo 会读取当前 CLI 版本、登录状态和本机实际可见模型目录。
4. 在“角色模型分工”中，让每个角色跟随 CLI 默认模型，或从动态目录选择不同模型与 reasoning effort。
5. 在“编排蓝图”中调整最多 8 个角色，并按 `1 → 2 → 3 → …` 排列任意数量步骤。
6. 在“运行监控”启动流程。遇到人工门控时批准后继续；步骤产物默认折叠，展开后由内置 Markdown Viewer 渲染，关键内容会自动拆分并进入当前项目的共享记忆。

当前 DMG 是 Apple Silicon `arm64` 本地开发构建，使用 ad-hoc 签名，未做 Developer ID 签名和 Apple 公证。如果另一台 Mac 的 Gatekeeper 拦截，应在 Finder 中右键 AiGo 选择“打开”；它不适合作为公开发布包。

## 0.1.1 已实现

- 原生 SwiftUI macOS 桌面端与半透明玻璃界面；
- 多项目工作区；每个项目独立拥有“编排蓝图、运行监控、共享记忆、Codex 设置”；
- 最多 8 个智能体席位，步骤数量不受席位上限影响，同一角色可以执行多个步骤；
- 顺序执行、步骤重排、执行前人工批准、审核输出 `VERDICT: FAIL` 后自动回退一次；
- 本机 CLI 动态模型目录，不硬编码某个 Codex 模型；
- 角色级模型和推理强度选择，留空模型时跟随 Codex CLI 当前默认模型；
- 真实执行命令为 `codex exec --json --ephemeral --sandbox read-only`，提示词走标准输入；
- 解析 CLI JSONL 中的线程、智能体消息、活动、错误和 token 用量；
- 项目工作目录可按项目输入或选择，留空时使用 AiGo 托管目录；该路径实际传给 CLI 的 `-C`；
- 任务指令使用稳定编辑草稿，后台自动记忆同步不会在输入过程中替换或清空文本；
- 自动共享记忆：将步骤成果拆为事实、决策、约束、风险和后续行动，用稳定键去重修订；
- 有效知识与修改日志/运行摘要分层；审计日志永不注入模型，每步只按相关性选择最多 14 条、9,000 字符；
- 累计交接只保留最近一步的有界详细结果和至多 8 个较早步骤的压缩摘要，避免深层流程无限增长；
- 运行监控的步骤产物默认折叠，展开后支持标题、列表、表格、引用和代码块等 Markdown 显示；
- 每个项目保存最近 20 次运行归档，持久知识最多 120 条、审计日志最多 60 条；
- 0.1.0 单项目 JSON 自动备份并迁移到 0.1.1 多项目结构。

0.1.1 刻意不做多用户、云同步、其他模型平台、直接 HTTP API、模型写文件或任意 shell 写入。CLI 被放在 read-only 沙箱中，本版主要验证“编排、角色调度、上下文传递和自动共享记忆”。

## 实际调用边界

每个步骤启动一次独立子进程：

```text
codex exec \
  --json \
  --ephemeral \
  --sandbox read-only \
  --skip-git-repo-check \
  --color never \
  -C <当前项目工作目录> \
  [--model <该角色选择的模型>] \
  --config model_reasoning_effort="<该角色强度>" \
  -
```

- 模型留空时省略 `--model`，由 CLI 使用自身当前默认模型。
- `--ephemeral` 避免把这些内部角色步骤写进普通 CLI 会话历史。
- `--sandbox read-only` 阻止本版模型修改项目文件。
- AiGo 继承本机进程环境并补充 Homebrew 常见路径，以便从 Finder 启动时也能找到 `/opt/homebrew/bin/codex`。
- AiGo 不接触用户的 ChatGPT/Codex 登录凭据，只让 CLI 自己处理认证。

## 自动共享记忆

```text
项目蓝图变更 ──> 主脉络同步 + 修改日志
                       │
CLI 步骤完成 ───> 拆分“共享记忆更新”为原子知识
                       │
                       ├── 稳定键相同：更新原记录并增加修订号
                       └── 无稳定键：按规范化内容去重
                       │
配置修改/运行结束 ──> 修改日志/运行摘要（仅审计）
                       │
                       ▼
主脉络 + 与当前角色/任务相关的细粒度知识
                       │
                       ▼
        固定预算（最多 14 条 / 9,000 字符）
                       │
                       ▼
                下一角色的提示上下文
```

系统自动维护每条知识的类型、来源、稳定键、关联步骤、关联运行、修订号和更新时间。项目主脉络会随路径、角色、模型和步骤顺序变化自动更新；步骤提示要求模型在 `## 共享记忆更新` 中输出最多 10 条带类型和稳定短键的原子知识。同一主题复用稳定键会覆盖更新原记录。修改日志和运行摘要放在独立“审计日志”视图，绝不占用后续模型上下文。持久层还会压缩为 1 条主脉络、最多 120 条知识和 60 条审计记录。

## 本地数据与迁移

```text
~/Library/Application Support/AiGo/workspace.json
~/Library/Application Support/AiGo/workspace-v0.1.0-backup.json
~/Library/Application Support/AiGo/Projects/<Project UUID>/
```

项目库 JSON 包含所有项目及其四个模块的数据。每个项目可以改用任意现有绝对路径；自定义目录只作为 CLI 工作目录，AiGo 不负责删除。检测到旧单项目结构时，AiGo 先复制原文件为备份，再迁移；旧固定模型配置会改成“跟随 CLI 默认模型”，旧已批准记忆会保留为迁移记忆。

## 代码边界

```text
Sources/AiGo/Domain
  Models.swift                  多项目、角色、步骤、CLI 配置、记忆、运行模型

Sources/AiGo/Services
  WorkspaceStore.swift          项目库持久化、迁移、项目切换和自动变更检测
  CodexCLIService.swift         CLI 检测、动态模型目录、子进程和 JSONL 解析
  OrchestrationEngine.swift     顺序状态机、门控、回退、取消和自动记忆钩子
  PromptComposer.swift          角色任务、共享记忆与上游产物的提示组装
  AutomaticMemoryService.swift 主脉络、修改日志、步骤成果与运行摘要

Sources/AiGo/Views              四个项目级模块和项目导航
Sources/AiGo/DesignSystem       玻璃视觉系统与原生 Markdown Viewer
Sources/AiGoApp                 macOS 应用入口
Sources/AiGoSelfTests           无第三方依赖的集成测试入口
Resources                      Info.plist 与空权限声明
Scripts                        测试、构建、DMG、清理脚本
Dist                           最终 .app 与 .dmg
```

完整 0.1.1 路线见 [`../Tec/AiGo-0.1.1-本机CodexCLI多项目编排技术路线.md`](../Tec/AiGo-0.1.1-本机CodexCLI多项目编排技术路线.md)。HermesPet 源码技术路线还原见 [`../Tec/HermesPet-完整技术路线分析.md`](../Tec/HermesPet-完整技术路线分析.md)。

## 测试与打包

要求 Apple Silicon Mac、Swift 6 工具链和 macOS SDK 14 或更高版本。本机当前 Command Line Tools 的 SDK 与编译器小版本不匹配，因此脚本在存在时显式使用兼容的 macOS 15.4 SDK；其他机器可用 `AIGO_SDK_PATH` 覆盖。

```bash
./Scripts/run-tests.sh
./Scripts/package-dmg.sh
./Scripts/clean.sh
```

`run-tests.sh` 当前包含 67 项断言，覆盖动态目录解析、旧数据迁移、多项目和路径隔离、任务输入稳定性、细粒度记忆去重与硬预算、深流程有界交接，以及假 CLI 端到端编排。`package-dmg.sh` 产出 `Dist/AiGo-0.1.1-AppleSilicon.dmg`，验证签名、DMG 和 Mach-O 架构，并打印 SHA-256；所有临时构建目录在脚本退出时清理。
