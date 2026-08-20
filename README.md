# AiGo 0.1.4

AiGo 是一个本地优先的 macOS 科研智能体编排工作台。它让用户组织最多 8 个角色，自己编辑 `1 → 2 → 3 → …` 流程，或者让选定的“总体设计师”先通过本机 Codex CLI 生成完整草案，再由用户修改、追加或整体采用。

0.1.4 不使用 OpenAI API Key，没有离线演示模式，也不把模型固定成某个版本。所有智能体调用都启动用户已经登录的本机 `codex` CLI；模型留空时跟随 CLI 当前默认模型。

## 怎么试用

1. 先确认 Codex CLI 可用且已登录：

   ```bash
   codex --version
   codex login status
   ```

2. 打开 `Dist/AiGo.app`，或挂载 `Dist/AiGo-0.1.4-AppleSilicon.dmg` 后把 AiGo 拖入“应用程序”。
3. 在当前项目的“Codex 设置”里选择真实项目文件夹，点击“检测并刷新”。
4. 给设计师、信息收集员、代码员、审核员等角色选择 CLI 模型与 reasoning effort；也可全部跟随 CLI 默认。
5. 在“编排蓝图”里：

   - 点击“手动添加”，自己填步骤名称、任务指令、角色、权限和审核回环；
   - 或点击“分配任务”，选一名设计师生成 JSON 流程草案，在预览中修改后追加或替换现有流程。

6. 在“运行监控”启动完整流程。审核步骤返回 `AIGO_VERDICT: FAIL` 时，会把具体问题交给配置的更早步骤返工，然后重新走到审核；超过回环上限才停止。
7. 运行某个项目时可以直接切换或新建另一个项目并启动流程；每个项目拥有独立执行器、恢复状态、运行监控和数据回写。
8. 如果运行期间应用异常退出，下次打开对应项目时必须二选一：“从中断处继续”会保留已完成步骤并重试中断步骤；“回滚本次并重新运行”会恢复到该 Run 启动前的共享记忆、归档旧运行，再从第 1 步建立新 Run。

当前 DMG 是 Apple Silicon `arm64` 本地开发构建，使用 ad-hoc 签名，未做 Developer ID 签名和 Apple 公证。在其他 Mac 被 Gatekeeper 拦截时，可在 Finder 中右键 AiGo 选择“打开”。

## 0.1.4 已实现

- 原生 SwiftUI macOS 桌面端和半透明玻璃界面；
- 多项目工作区，每个项目独立保存蓝图、监控、共享记忆、Codex 设置和项目路径；
- 每项目一个 `OrchestrationEngine`，不同项目可同时启动各自的本机 Codex CLI 子进程；切换项目不取消、不重置其他项目的运行；
- 后台项目的步骤记忆、检查点、运行摘要和归档按 `projectID` 精确写回，不依赖当前界面选中的项目；
- 最多 8 个智能体席位，步骤数量不受席位上限影响；
- 手动顺序编排，可逐步编辑名称、任务指令、执行角色、输入范围、写入权限、人工门控和回环；
- “设计师分配任务”对话框，通过选定角色的本机 CLI 模型生成可编辑草案；
- 设计输出经 JSON 提取、字段解码、智能体 UUID 校验、空名称/空指令校验、重复 key 检查和前向回环拒绝；
- 草案中的所有步骤可折叠、修改、排序、删除；未填步骤名称或指令时禁止采用；
- 审核判定协议 `AIGO_VERDICT: PASS|FAIL`，支持 Markdown 包裹和全角冒号，未给明确标记时不再误当通过；
- 审核回环只能指向更早步骤，每个审核节点可设 1–5 次返工上限；
- FAIL 审核产物作为最近上游反馈交给返工步骤，但不进入有效共享知识；PASS 后才继续；
- 每个步骤独立选择 `read-only` 或 `workspace-write`；新建和缺少权限字段的迁移步骤默认允许写当前项目，审核员步骤默认只读；
- 代码角色与代码步骤的提示明确要求检查真实文件、落盘实现、运行测试/构建，禁止只给伪代码；
- CLI 模型目录动态解析，角色可跟随 CLI 默认或选择不同模型与推理强度；
- 自动共享记忆：主脉络、原子知识、稳定键去重修订、相关性选择、固定条数与字符预算；
- 项目级异常检查点：原子保存运行位置、已批准门控、审核回环计数、调用记录和部分输出；
- 启动恢复二选一，继续时不重跑已完成步骤，部分输出作为不确定线索交给中断步骤的新尝试；
- 每个新 Run 在独立文件中保存一次运行前记忆基线；重新运行时精确恢复基线，即使本次运行曾用 stableKey 覆盖旧知识也不会残留；
- 升级时识别 0.1.3 运行历史中明确的“用户选择重新开始”归档，自动清除其已知 runID 记忆残留；普通手动停止和正常运行知识不受影响；
- 兼容恢复 0.1.2 已归档但仍含 `.running` 调用的不完整取消记录，并从历史 FAIL 产物重建回环次数；
- 主场景改用可靠创建窗口的 `WindowGroup`，恢复卡片由单一 checkpoint item 驱动，避免重开后无主窗口或空白恢复弹层；
- 性能重做：工作区、检查点和收尾 JSON 编码/原子写入进入同一后台串行持久化通道，结束时摘要与归档合并成一次提交；
- 流式检查点节流、步骤记忆整批落盘、上下文预算收紧、设计师默认 3–6 步、默认推理强度下调；
- 步骤产物默认折叠，只有用户展开时才解析 Markdown；大段产物不会在终态刷新时全部抢占主线程；
- 项目库 schema 5，兼容旧项目；运行检查点使用独立 schema 1 文件，不让高频输出重写整个项目库。

## 实际 CLI 调用边界

每个步骤都启动一次独立子进程：

```text
codex exec \
  --json \
  --ephemeral \
  --sandbox <read-only|workspace-write> \
  --skip-git-repo-check \
  --color never \
  -C <当前项目工作目录> \
  [--model <该角色选择的模型>] \
  --config model_reasoning_effort="<该角色推理强度>" \
  -
```

- 模型留空时省略 `--model`，不固定任何版本。
- 设计师生成流程的调用始终是 `read-only`。
- 新建步骤默认使用 `workspace-write`，并以 `-C` 把可写边界限定在当前项目；审核员默认使用 `read-only`。
- 每一步仍可在蓝图中显式改回只读，设计师生成流程的那一次调用始终只读。
- `--ephemeral` 避免把内部角色步骤写入普通 CLI 会话历史。
- AiGo 不读取、保存或转发用户的 API Key 和 CLI 登录凭据。

## 设计师草案与有界回环

```text
用户分配要求 + 项目目标 + 现有角色/UUID + 现有流程
                              │
                              ▼
                选定设计师的本机 Codex CLI
                         (read-only)
                              │
                              ▼
                    单一 JSON 对象
                              │
         ┌──解码/校验/角色解析/回环解析──┐
         │                                            │
      无效：报错                                 有效：可编辑草案
                                                      │
                                  ┌──追加──┴──替换──┐
                                  ▼                  ▼
                              当前项目编排蓝图
```

JSON 中每个步骤使用一个临时 `key`。`review_return_to` 只能引用它之前的 key，导入时再映射为稳定 UUID。排序或删除使回环变成前向/悬空引用时，界面会自动取消该回环。

## 审核返工状态机

```text
执行审核步骤
      │
      ├─ 无 AIGO_VERDICT ─────────▶ 失败停止（不把未知当通过）
      │
      ├─ PASS ─────────────────▶ 写入有效记忆，继续下一步
      │
      └─ FAIL
           │
           ├─ 无有效早期目标 ───▶ 失败停止
           │
           ├─ 已达本审核节点上限 ─▶ 失败停止
           │
           └─ 仍可回环
                │
                ├─ FAIL 正文不写入有效共享记忆
                ├─ 作为最近上游交给返工步骤
                └─ 返工后顺序重跑至该审核节点
```

回环计数以审核步骤 UUID 为键，不同审核员即使返回同一步，也不会错误共用重试计数。回退后的提示会明确标记“审核失败后的回退重做”，并优先要求处理最近 FAIL 产物的修改清单。

## 异常退出恢复状态机

```text
启动/步骤开始/门控/回环/步骤完成 ──▶ 立即原子检查点
CLI 输出与活动流                     ──▶ 600ms 节流写最新检查点
                                           │
                     ┌── 正常完成/失败/主动停止 ──▶ 删除检查点
                     │
                     └── 进程异常退出 ─────────▶ 文件保留
                                                        │
                                         下次打开项目强制二选一
                                          │                  │
                                  从中断处继续       回滚本次并重新运行
                                  保留完成步骤       恢复 Run 前记忆基线
                                  恢复门控/回环       旧运行中断归档
                                  中断步骤新尝试       建立新 Run ID
```

检查点不复制项目蓝图和共享记忆，只保存运行期状态。另有 `RunMemoryBaselines/<Project UUID>.json` 在每个 Run 启动时保存一次共享记忆快照，不随输出流反复重写。继续运行沿用该事务；“回滚本次并重新运行”恢复完整基线，因此能撤销新增记录，也能恢复被 stableKey 原地修订的旧记录。正常完成、明确失败或主动停止后，项目摘要、运行归档、检查点清理和基线清理由一个后台收尾事务统一提交。

恢复时以当前项目蓝图为配置源，并把旧 `.running` 调用改成 `.interrupted`：已产生的正文继续可见，但不会伪装成完成结果。新尝试会先核对真实项目文件，再参考这段部分产物补齐工作。记忆回滚不承诺撤销 Codex 已经写入真实项目目录的文件；文件状态仍由后续步骤核对。

0.1.2 没有独立检查点，但它在取消时可能先归档 session、后终止执行，因此历史中会出现“session 已 cancelled、最后一次调用仍 running”的不一致记录。schema 4 首次升级时，0.1.3 会把这种记录一次性重建成项目检查点；普通且所有调用都已正确终止的取消记录不会误触发。

## 自动共享记忆

```text
项目蓝图变更 ──▶ 主脉络同步 + 修改日志（审计层）
CLI 步骤通过 ──▶ 拆分“共享记忆更新”为最多 10 条原子知识
                            │
                            ├─ 稳定键相同：修订原记录
                            └─ 无稳定键：按规范化内容去重
                            │
                            ▼
                相关性排序 + 10 条 / 6,000 字符预算
                            │
                            ▼
                    注入当前角色提示
```

FAIL 审核是一个特殊分支：它必须给立即返工提供反馈，却不能被当成已确认的长期知识。因此它保留在本次 Run 的上游交接中，但跳过 `integrateMemories`。运行摘要仍会作为审计记录保存，且永不注入模型。

性能上，单个步骤提取出的多条知识先在内存中完成稳定键 upsert，再一次性提交；不再为每条知识重复编码整个项目库。所有 JSON 编码和原子文件替换在后台串行通道中保持提交顺序，主线程只更新 SwiftUI 状态。结束时运行摘要与历史归档使用同一份项目快照，不再连续重写项目库。累计上游交接从 12,000 收紧到 8,000 字符，最近正文从 7,000 收紧到 4,500 字符，更早步骤只保留最近 6 个压缩摘要。

## 项目级并行

```text
ProjectRunRegistry
  ├─ Project A UUID ──▶ OrchestrationEngine A ──▶ codex exec A
  ├─ Project B UUID ──▶ OrchestrationEngine B ──▶ codex exec B
  └─ Project C UUID ──▶ OrchestrationEngine C ──▶ codex exec C
                              │
                              ▼
                 WorkspaceStore(projectID 定向提交)
```

同一项目仍严格遵守用户编排的 `1 → 2 → 3` 顺序，且同一项目同一时刻只允许一个活动 Run；“项目之间并行”不会擅自改变项目内部的依赖语义。切换侧边栏只改变当前观察与编辑对象，不调用其他引擎的 `resetMonitor()`。项目正在运行时只锁定该项目的蓝图和设置，其他项目仍可编辑、启动、停止或等待人工门控。

## 代码边界

```text
Sources/AiGo/Domain/
  Models.swift                   schema 5、步骤权限、运行/检查点状态和回环上限

Sources/AiGo/Services/
  WorkspaceStore.swift           projectID 定向更新、记忆事务、异步串行持久化及原子收尾
  ProjectRunRegistry.swift       每项目独立执行器、状态转发和并行运行计数
  CodexCLIService.swift          按步骤传递 sandbox、CLI JSONL 和一次性完成接口
  WorkflowDesignService.swift    设计师提示、本机 CLI 调用、JSON 解析与安全校验
  ReviewVerdictParser.swift      PASS/FAIL 显式标记解析
  OrchestrationEngine.swift      单项目顺序状态机、有界回环、边界快照和中断恢复
  RunLaunchCoordinator.swift     新运行/重新开始/继续运行的统一启动与回调接线
  PromptComposer.swift           角色、任务、权限、回退反馈、共享记忆与上游交接
  AutomaticMemoryService.swift  主脉络、原子记忆、稳定键修订和硬预算

Sources/AiGo/Views/
  BlueprintView.swift            “分配任务”入口、手动步骤编辑与回环属性
  WorkflowDesignerView.swift     设计师选择、要求输入、草案预览与采用
  MainView.swift                 项目切换和不可跳过的异常恢复二选一界面
  RunMonitorView.swift           惰性折叠 Markdown 产物、权限/中断标记、回环时间线
  SettingsView.swift             项目路径、动态模型和执行边界

Sources/AiGo/SelfTestSuite.swift 无第三方依赖的迁移、草案、CLI、记忆与回环集成测试
```

## 本地数据与迁移

```text
~/Library/Application Support/AiGo/workspace.json
~/Library/Application Support/AiGo/workspace-v0.1.0-backup.json
~/Library/Application Support/AiGo/RunCheckpoints/<Project UUID>.json
~/Library/Application Support/AiGo/RunMemoryBaselines/<Project UUID>.json
~/Library/Application Support/AiGo/Projects/<Project UUID>/
```

项目库 JSON 包含所有项目及其四个模块的数据。自定义项目目录只作为 CLI 工作目录，AiGo 不会删除、重命名或整理用户项目。旧数据中没有 `executionAccess` 的步骤迁移为 `workspace-write`，已明确保存的权限保持不变；没有 `maxReviewRetries` 时默认为 1。检查点和运行记忆基线只由 AiGo 删除，不触碰用户项目文件。

## 测试与打包

需要 Apple Silicon Mac、Swift 6 工具链和 macOS SDK 14 或更高版本。

```bash
./Scripts/run-tests.sh
./Scripts/package-dmg.sh
./Scripts/clean.sh
```

154 项自测覆盖动态模型目录、schema 5 迁移、0.1.2 不完整运行重建、多项目与路径隔离、任务指令稳定性、设计师 JSON 解析、空字段拦截、非法回环拒绝、默认写权限、真实工作目录落盘、审核 FAIL→返工→PASS、检查点跨启动读取、部分产物恢复、门控延续、stableKey 覆盖后的精确记忆回滚、旧版重新开始残留清理、普通取消知识保护、两个项目同时运行、后台 projectID 回写隔离、批量记忆和深层流程有界交接。

`package-dmg.sh` 产出 `Dist/AiGo-0.1.4-AppleSilicon.dmg`，验证签名、DMG 和 Mach-O `arm64` 架构并打印 SHA-256。构建和测试的临时目录会由脚本或 `clean.sh` 清理，`Dist` 交付物保留。

完整 0.1.4 实现路线见 [`../Tec/AiGo-0.1.4-记忆事务与项目并行技术路线.md`](../Tec/AiGo-0.1.4-记忆事务与项目并行技术路线.md)；0.1.3 的异常恢复与性能基础见 [`../Tec/AiGo-0.1.3-异常恢复与执行性能技术路线.md`](../Tec/AiGo-0.1.3-异常恢复与执行性能技术路线.md)，完整项目原始分析仍在 [`../Tec/HermesPet-完整技术路线分析.md`](../Tec/HermesPet-完整技术路线分析.md)。
