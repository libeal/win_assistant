# Windows AI 终端助理

> 我们一起构建的 Windows 本地 PowerShell 智能助理：用自然语言驱动命令执行，同时保留可控与安全。

Windows AI 终端助理运行在本地 PowerShell 环境中，负责把用户需求转成结构化命令、提示风险并执行。它支持多轮上下文、附件注入、会话日志以及 MCP 外部能力扩展，帮助你在 Windows 上更高效地完成日常任务与运维工作。

## ✨ 功能亮点

- **自然语言转命令**：输出结构化 JSON，区分问答与命令执行
- **执行前确认**：逐条命令展示预期效果，用户确认后执行
- **智能备份**：涉及写入/删除时，自动解析路径并提供压缩备份选项
- **上下文记忆**：可配置的多轮对话摘要注入
- **附件支持**：本地文件/图片转 Base64 或 data URI 注入下一次请求
- **MCP 扩展**：支持 SSE/WebSocket/stdio/streamableHttp 调用外部工具
- **会话日志**：完整记录计划、命令、输出与错误，自动导出 Markdown

## 🚀 快速开始

### 环境要求

- Windows
- PowerShell（建议 7+，Windows PowerShell 5 也兼容）
- OpenAI 兼容接口（或任意兼容 Chat Completions 的服务）

### 安装与配置

1. 解压或克隆项目到本地
2. 编辑 `config.json`，填写 API 信息

```json
{
  "aiProvider": "OpenAI",
  "apiKey": "your-api-key",
  "apiUrl": "https://api.openai.com/v1/chat/completions",
  "model": "gpt-4o-mini",
  "maxContextTurns": 3
}
```

可选字段（按需添加）：

- `requestTimeoutSec`：AI 请求超时（秒）
- `response_format`：兼容 OpenAI 的 `response_format` 结构
- `userPromptSuffix`：附加到用户输入后的自定义提示

> 提示：支持环境变量 `WINDOWS_AI_MOCK=1` 进入 Mock 模式，跳过真实 API。

### 启动

双击 `main.bat`，或在 PowerShell 中运行：

```powershell
.\main.bat
```

输入 `exit` 结束会话并导出日志。

## 🧭 使用示例

### 自然语言转命令

```
用户：帮我创建一个名为 MyProject 的文件夹
AI：  计划概述：将在当前目录创建文件夹
      是否执行此命令？(Y/N)
用户：Y
AI：  [完成] 命令已执行。
```

### 触发备份

```
用户：删除桌面上的 old_report.txt
AI：  检测到文件操作，是否先生成备份？(Y/N)
用户：Y
AI：  [备份] 已生成压缩包
      是否执行此命令？(Y/N)
```

### 附件注入

```powershell
Add-AIAttachment -Paths 'report.pdf' -Note '请先阅读并总结'
Get-PendingAIAttachments
Clear-PendingAIAttachments
```

### MCP 调用

```powershell
Invoke-McpRequest -Method 'tools/list' -Service 'example-server'
```

## ⚙️ 配置说明

### config.json

- `aiProvider`：目前主要验证 `OpenAI`，也支持 `Mock`
- `apiKey`：API 密钥
- `apiUrl`：Chat Completions 端点
- `model`：模型名称
- `maxContextTurns`：上下文轮数（0 表示关闭）

### mcp.config.json

支持多服务注册与默认服务设置，传输类型包括 `sse`、`websocket`、`stdio`、`streamableHttp`。

### personalization.md

用于记录长期信息，系统会在每次 AI 调用前注入（不占用上下文记忆）。例如：

```markdown
# 个性化配置

常用开发目录：D:\code
常用代理：http://proxy:port
```

## 🧩 项目结构

```
win_assistant-main/
├─ README.md                 # 项目说明
├─ main.bat                  # 启动入口（设置 UTF-8）
├─ core.ps1                  # 主流程控制器
├─ config.json               # AI 配置
├─ mcp.config.json           # MCP 服务配置
├─ mcp.md                    # MCP 使用提示
├─ mcpnew.md                 # MCP 参考文档（扩展说明）
├─ personalization.md        # 个性化配置
├─ test-api.ps1              # API 连接测试脚本
├─ logs/                     # 会话日志与 MCP 跟踪
│  ├─ SessionLog_*.md         # 自动生成的会话日志
│  └─ mcp-trace.log           # MCP 调用追踪日志
└─ modules/                  # 功能模块
   ├─ ai-api.psm1            # AI API 调用实现
   ├─ ai-api.ps1             # 兼容入口（加载 .psm1）
   ├─ attachments.psm1       # 附件处理实现
   ├─ attachments.ps1        # 兼容入口（加载 .psm1）
   ├─ backup.psm1            # 备份流程实现
   ├─ backup.ps1             # 兼容入口（加载 .psm1）
   ├─ common.psm1            # 通用工具函数
   ├─ common.ps1             # 兼容入口（加载 .psm1）
   ├─ executor.psm1          # 命令执行与确认
   ├─ executor.ps1           # 兼容入口（加载 .psm1）
   ├─ logger.psm1            # 会话日志实现
   ├─ logger.ps1             # 兼容入口（加载 .psm1）
   ├─ mcp.psm1               # MCP 调用实现
   ├─ mcp.ps1                # 兼容入口（加载 .psm1）
   ├─ personalization.psm1   # 个性化配置读取
   └─ personalization.ps1    # 兼容入口（加载 .psm1）
```

## ✅ 行为约定

- **只执行确认过的命令**：逐条确认，默认安全
- **高风险命令拒绝或提示**：避免系统级破坏操作
- **UTF-8 输入输出**：读写文件与日志统一 UTF-8

## 🧪 测试与排错

- `.\test-api.ps1`：测试 API 连通性
- `logs/`：会话日志与 MCP 调用跟踪
