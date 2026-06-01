# 设计：AI History Session

- 日期：2026-06-01
- 状态：设计已确认，待用户 review
- 范围：主桌面应用，不涉及 `remote/` Web 控制台

## 1. 背景与目标

WispTerm 已经有内置 AI Chat / AI Agent 会话历史，但 Codex CLI 和 Claude Code
自己的会话记录分别存放在目标机器的用户家目录下，例如 `$HOME/.codex` 和
`$HOME/.claude`。用户希望从 WispTerm 里创建一种新的 session，像连接 SSH
服务器一样连接到一个 Local / WSL / SSH 目标，然后浏览该目标上的 Codex /
Claude Code 历史记录，并能在正确项目目录里恢复会话。

本设计定义新的 **AI History Session**：

1. 从 `New Session` 打开。
2. 一个 session 绑定一个目标，首版目标为 Local、单个 WSL distro、单个 SSH profile。
3. 连接后扫描该目标 `$HOME/.codex` 和 `$HOME/.claude`，也支持 source 级路径覆盖。
4. 首版只做浏览和恢复，不做删除、归档、重命名等会修改目标历史文件的操作。

## 2. 关键设计决策

| 维度 | 决定 |
|---|---|
| UI 层级 | 新的主工作区 tab，不是右侧附属 panel，也不是 command-center overlay |
| tab 类型 | 新增非终端 tab kind，独立于 `terminal` 和现有 `ai_chat` |
| 目标模型 | 混合模式：连接信息复用 Local / WSL / SSH profile，AI History 自己保存扫描设置 |
| 目标数量 | 首版一个 AI History Session 只绑定一个目标；聚合多个目标以后再做 |
| Provider | 首版固定 Codex + Claude Code |
| 路径 | 默认 `$HOME/.codex`、`$HOME/.claude`，允许每个 source 覆盖或追加 root |
| 扫描 | 打开时后台扫描元数据，写本地索引缓存；点开记录时懒加载 transcript |
| 搜索 | 首版只索引元数据；详情页支持当前 transcript 内查找 |
| Resume | 新建真实终端 tab，在同一目标、原始项目目录中执行 provider resume 命令 |
| 路径缺失 | 首版失败并显示原因，不回退到 `$HOME`；未来可加路径修改确认 |

## 3. Ghostty 对照

Ghostty 的相关设计重点不是 AI 历史浏览，而是职责边界：

- `Surface` 是终端交互单元，负责 PTY、输入输出和渲染。
- `SplitTree` 管理终端 view 的布局、split、resize、focus。
- 非终端的应用级工具不应该伪装成 PTY surface。

WispTerm 的实现应保持同样边界：AI History 是 app-level 的浏览 tab，不进入
terminal `Surface` / `SplitTree`。只有用户点击 `Resume` 时，才创建真正的终端
surface，连接到同一个目标并运行 Codex / Claude Code 的恢复命令。

## 4. 架构

### 4.1 新 tab kind

扩展 `src/appwindow/tab.zig` 的 `TabState.Kind`：

```zig
pub const Kind = enum {
    terminal,
    ai_chat,
    ai_history,
};
```

`TabState` 新增 `ai_history_session: ?*ai_history_session.Session`。终端 tab
继续持有 `SplitTree`，AI Chat tab 继续持有 `ai_chat.Session`，AI History tab
持有自己的浏览状态和扫描状态。

`AppWindow` 只负责：

- 创建 / 关闭 / 切换 AI History tab。
- 调用 `renderer/ai_history_renderer.zig` 绘制当前 AI History tab。
- 把输入路由给 AI History tab。
- 在 `Resume` 时调现有终端创建路径。

### 4.2 模块划分

新增模块建议：

| 模块 | 职责 |
|---|---|
| `src/ai_history_session.zig` | AI History tab 的状态机：source、扫描进度、过滤器、选中项、transcript lazy load、resume 请求 |
| `src/ai_history_source.zig` | Source profile：目标引用、provider 开关、root 覆盖、cache key |
| `src/ai_history_provider_codex.zig` | Codex JSONL 扫描、metadata 解析、transcript 解析、resume 命令描述 |
| `src/ai_history_provider_claude.zig` | Claude Code JSONL 扫描、metadata 解析、transcript 解析、resume 命令描述 |
| `src/ai_history_cache.zig` | 本地 metadata index 读写，不默认缓存全文 |
| `src/renderer/ai_history_renderer.zig` | 三栏/两栏浏览 UI 渲染与 hit testing |

不要把 provider 扫描逻辑放进 `renderer/overlays.zig`、`file_explorer.zig` 或现有
`ai_chat.zig`。这些文件已经承担较多职责，新功能应通过独立模块进入。

## 5. Source 与连接目标

### 5.1 Source 模型

`AiHistorySource` 保存浏览设置，不复制 SSH 密码或连接凭证：

```zig
pub const Target = union(enum) {
    local,
    wsl: WslTarget,
    ssh: SshTargetRef,
};

pub const AiHistorySource = struct {
    id: []const u8,
    name: []const u8,
    target: Target,
    providers: ProviderFlags,
    codex_root_override: ?[]const u8,
    claude_root_override: ?[]const u8,
    extra_roots: []const ProviderRoot,
};
```

SSH source 只保存 profile 引用，连接细节继续从现有 SSH profile 读取。WSL source
保存 distro 标识；首版可先使用默认 distro，若 session launcher 已有 distro 选择能力再扩展。

### 5.2 HOME 获取

打开 AI History tab 时先获取目标 `$HOME`：

- Local：平台 home 目录。
- WSL：在目标 distro 内执行 `printf %s "$HOME"`。
- SSH：通过现有 SSH profile 启动受控 helper 命令 `printf %s "$HOME"`。

HOME 获取失败是 source 级错误，tab 保留并显示 Retry。

## 6. Provider 解析

### 6.1 统一 metadata

扫描列表只生成 `SessionMeta`，不加载完整 transcript：

```zig
pub const SessionMeta = struct {
    provider: ProviderId,
    session_id: []const u8,
    title: []const u8,
    summary: []const u8,
    project_dir: []const u8,
    created_at_ms: i64,
    last_active_at_ms: i64,
    source_path: []const u8,
    resume_kind: ResumeKind,
    message_count: u32,
    scan_status: ScanStatus,
};
```

`project_dir` / `cwd` 是 resume 的硬依赖，解析不到时该记录仍可浏览，但 `Resume`
按钮应显示不可用原因。

### 6.2 Codex

默认扫描 `$HOME/.codex`，兼容 Codex 的 sessions / archived sessions 目录布局。
Provider 负责从 JSONL 中提取：

- session id。
- `session_meta` 里的 cwd / project dir。
- 用户可读 title / summary。
- `createdAt`、`lastActiveAt`。
- 可展示消息数量。

Transcript 懒加载时跳过纯环境块、`AGENTS.md` 注入块、明显的 meta 噪音；保留用户
消息、assistant 消息和必要的 tool 摘要。Resume 命令为：

```text
codex resume <session_id>
```

### 6.3 Claude Code

默认扫描 `$HOME/.claude`，优先兼容 Claude Code 的 projects JSONL 目录布局。Provider
负责从 JSONL 中提取：

- session id。
- cwd / project dir。
- title，优先级为自定义 title、首个真实用户消息、project dir basename。
- `createdAt`、`lastActiveAt`。
- 可展示消息数量。

Transcript 懒加载时跳过 `isMeta` 内容，把纯 tool result 的 user 消息折叠为 tool
内容，避免正文被工具噪音淹没。Resume 命令为：

```text
claude --resume <session_id>
```

## 7. 扫描与缓存

### 7.1 扫描策略

打开 tab 时自动启动后台扫描：

1. 获取 target `$HOME`。
2. 根据 provider 默认 root、覆盖 root 和 extra root 生成扫描路径。
3. 扫描 JSONL 文件候选。
4. 读取每个文件足够生成 metadata 的内容。
5. 更新本地 metadata cache。
6. UI 持续显示 provider 级进度和警告。

扫描不能阻塞 UI 线程。远程扫描必须有文件数、单文件大小、总耗时上限。超限时记录
partial 状态，已经扫描出的 metadata 仍然可浏览。

### 7.2 缓存边界

本地 cache 只保存 metadata index 和扫描状态，不默认保存 transcript 全文。用户点开某条
记录时，才从目标重新读取 `source_path` 并解析 transcript。

建议 cache key 包含：

- source id。
- target identity：local machine、WSL distro、SSH profile name / host / user / port。
- provider id。
- provider root path。
- source file path、size、mtime。

如果 size/mtime 未变化，可复用已有 metadata。

## 8. UI 行为

AI History tab 是类似 AI Chat 的全屏主 tab，但内容是浏览工作台：

- 左侧：Source 状态、目标名、连接状态、扫描状态、provider 开关、刷新按钮、搜索框。
- 中间：Session 列表，按 `last_active_at_ms` 倒序，支持 provider、项目目录、时间和元数据搜索过滤。
- 右侧：Transcript 详情。未选中时显示空状态；选中后懒加载全文。

详情操作：

- `Copy`：复制当前 transcript 或选中消息。
- `Find in transcript`：只查当前已加载 transcript。
- `Resume`：触发恢复流程。
- `Refresh`：重新扫描当前 source。

长 tool output 默认折叠；普通 user / assistant 消息按聊天气泡或紧凑 transcript
样式显示。首版不需要在列表里展示全文命中。

## 9. Resume 行为

点击 `Resume` 时：

1. 使用记录的 target 创建新的终端 tab。
2. 连接到同一个 Local / WSL / SSH 目标。
3. 在目标上校验 `project_dir` 存在且可进入。
4. 只有校验通过才执行 `cd <project_dir>`。
5. 在该目录执行 provider resume 命令。

路径不存在、权限不足或 shell quoting 失败时，不执行 resume 命令，显示错误。首版不
回退到 `$HOME`，避免恢复到错误项目上下文。未来可增加路径修改确认框。

命令构造必须走平台 shell quoting helper，覆盖空格、单引号、`~`、Windows 路径、WSL
路径和 SSH 远端 POSIX 路径。

## 10. 错误处理

| 场景 | 行为 |
|---|---|
| 连接失败 | tab 保留，显示目标连接错误和 Retry |
| HOME 获取失败 | source 级失败，不扫描 provider |
| Provider root 不存在 | 标记该 provider 为 `not_found`，不作为致命错误 |
| 单个 JSONL 损坏 | 跳过该文件，保留 provider 警告 |
| 扫描超时或超限 | 显示 partial 状态，保留已发现记录 |
| Transcript 懒加载失败 | 只影响当前详情区，提供 Retry |
| Resume 路径不存在 | 失败并显示路径，不执行 resume |
| Resume 命令缺失 | 显示 Codex/Claude 可执行文件不可用，不关闭 History tab |

## 11. 测试策略

### 11.1 Provider 单测

- Codex JSONL 样例生成正确 `SessionMeta`。
- Claude JSONL 样例生成正确 `SessionMeta`。
- 跳过 meta / tool 噪音，但 transcript 仍保留必要 tool 摘要。
- session id、project dir、source path、时间排序稳定。
- 损坏 JSONL 不影响其他文件。

### 11.2 Source 与路径测试

- Local / WSL / SSH target 生成正确默认 root。
- root override 和 extra root 覆盖默认行为。
- shell quoting 覆盖空格、单引号、`~`、远端 POSIX path。
- HOME 获取失败时进入明确错误状态。

### 11.3 Cache 测试

- 扫描只写 metadata，不写 transcript 全文。
- 文件 size/mtime 未变化时复用 metadata。
- 文件变化时更新 metadata。
- partial scan 状态可以被下一次手动刷新清除。

### 11.4 Resume 测试

- Resume 必须先校验 project dir。
- project dir 不存在时不执行 resume 命令。
- Codex resume 命令和 Claude resume 命令分别正确。
- Local / WSL / SSH 三类目标都在同一目标和同一项目目录中启动。

### 11.5 UI 状态测试

- loading、empty、provider not found、partial warning、connection failed。
- transcript load failure 后 Retry。
- metadata 搜索和 provider 过滤。
- 关闭 AI History tab 释放 session 状态，不影响普通 terminal / AI Chat tab。

## 12. 非目标

- 不做多目标聚合总览。
- 不删除、归档、重命名 Codex / Claude 原始历史文件。
- 不默认缓存全文 transcript。
- 不把外部 Codex / Claude 历史合并进 WispTerm 内置 AI Chat history store。
- 不把 AI History 做成 terminal split / PTY surface。
- 不要求首版全文索引远程历史。

## 13. 成功标准

1. `New Session` 可以创建 AI History Session。
2. AI History Session 可绑定 Local / WSL / SSH 目标。
3. 连接成功后能扫描目标 `$HOME/.codex` 和 `$HOME/.claude` 的 metadata。
4. 列表可按 provider、项目目录、时间、元数据搜索过滤。
5. 点开记录才读取 transcript。
6. 点击 Resume 会在同一目标的原始项目目录打开真实终端并执行正确 resume 命令。
7. 原始项目目录不存在时，Resume 明确失败且不执行命令。
8. 扫描和远程读取不会阻塞 UI 线程。
