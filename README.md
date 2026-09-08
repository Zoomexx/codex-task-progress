# Codex 任务进度 · v0.4.0

一个只读的 macOS 悬浮任务面板：从本机 `~/.codex/sessions` 会话日志和
`~/.codex/session_index.jsonl` 读取 Codex 对话名称、状态、步骤、耗时和 token
事件，在所有桌面上显示“进行中 / 已完成”任务进度。

## v0.4.0 更新

- 主面板保持紧凑、半透明，鼠标悬停时恢复不透明；不使用滚动条。
- 进行中始终在上方，已完成始终在下方；每栏显示最近任务，其余任务在独立详情窗口中查看。
- 点击任务通过 `codex://threads/<session_id>` 打开对应 Codex 会话；深链不可用时才回退到打开应用或定位本地日志。
- 详情窗口显示任务名称、已处理时间、当前步骤、本轮消耗 token 和待授权状态；鼠标离开主面板与详情窗口后自动隐藏。
- “累计已消耗”直接读取全部本地会话日志中每个日志的最新 `total_token_usage` 快照，并按日志文件去重，不把任务本轮消耗相加。
- 同一会话日志中的并行任务保持独立基线；不会把多个任务误合并或重复计算。
- 用量栏使用官方 Codex App Server 的只读 `account/rateLimits/read` 与更新事件；不创建对话、不启动模型回合、不读取 Cookie、Token、私有数据库或网页快照。
- 面板使用无边框窗口，只绘制一套连续圆角边框，避免系统原生底边与其他边框不一致。

## 构建与运行

要求 macOS 和 Swift 编译器；不需要第三方依赖。

```bash
./build-app.sh
open CodexTaskProgress.app
```

构建临时版本而不覆盖默认输出：

```bash
CODEX_TASK_PROGRESS_BUILD_APP_DIR=/private/tmp/CodexTaskProgress-preview.app ./build-app.sh
```

解析器冒烟测试：

```bash
cache=$(mktemp -d /private/tmp/codex-task-progress-module-cache.XXXXXX)
swiftc Sources/UsageSnapshot.swift Sources/OfficialUsageClient.swift \
  Tests/UsageSyncParserSmoke.swift -module-cache-path "$cache" \
  -o /private/tmp/UsageSyncParserSmoke
/private/tmp/UsageSyncParserSmoke
```

## 数据边界与隐私

程序只读取当前用户本机 Codex 会话日志和本机 Codex App Server 的限额响应，
不上传任务标题或日志正文，不执行账户操作，不修改网页，不保存 Cookie、认证
Token、账户标识或截图。官方用量快照和本地日志累计值是不同口径：状态栏显示
官方限额剩余量，任务详情中的本地累计值显示会话日志记录的累计 token。

## 版本

- `v0.4.0` — 2026-09-08：任务深链、全量日志累计 token、无边框面板、详情交互和官方用量同步整合版。

许可证见 [`LICENSE`](LICENSE)。
