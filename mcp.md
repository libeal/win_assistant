# MCP 调用提示

本文件用于告诉 AI 如何通过 MCP 服务请求外部能力，请勿写入敏感信息。

- 调用入口：在 commands 数组中返回 PowerShell 命令 `Invoke-McpRequest -Method '<JSON-RPC方法>' -Params <参数对象> [-Service '<服务名>']`，执行器会直接执行并回显结果。
- 默认服务：`open-websearch`（SSE，超时时间 60 秒），适合网页检索或快速信息查询。
- 重要：MCP 的“工具名”不等于 `-Method`。例如 `search` 是工具名，应通过 `tools/call` 调用，而不是 `-Method 'search'`。
- 推荐示例：
  - 列出工具：`Invoke-McpRequest -Method 'tools/list' -Service 'open-websearch-local'`
  - 调用 search 工具：`Invoke-McpRequest -Method 'tools/call' -Params @{ name = 'search'; arguments = @{ query = '<关键词>'; engines=@('bing'); limit=10 } } -Service 'open-websearch-local'`
  - 简化写法（推荐）：`Invoke-McpToolCall -ToolName 'search' -Arguments @{ query = '<关键词>'; engines=@('bing'); limit=10 } -Service 'open-websearch-local'`
- 命令输出是一个对象，包含 `success`、`error`、`service`、`transport`、`data` 等字段；请在 effect 中描述期望用途，避免生成与需求无关的调用。
- 仅在需要 MCP 能力时生成上述命令；不需要时保持 commands 为空以减少不必要的请求。
- 支持服务发现：可先调用 `tools/list`、`resources/list`、`prompts/list` 了解服务能力。
- 超时与重试：遵循 mcp.config.json 中的 `timeoutSec` / `idleTimeoutSec` / `totalTimeoutSec` / `retry` 配置；如无配置默认使用 60 秒超时、1 次重试。
