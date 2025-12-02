# modules/ai-api.ps1
function Repair-AIJsonEscapes {
    <#
        .SYNOPSIS
            修复 AI 输出中未转义的反斜杠，避免 JSON 解析失败。
    #>
    param (
        [string]$RawText
    )

    if (Test-StringEmpty -Value $RawText) {
        return $RawText
    }

    return [regex]::Replace($RawText, '\\(?!["\\/bfnrtu])', '\\')
}

function Remove-AIResponseCodeFence {
    <#
        .SYNOPSIS
            去除 AI 可能输出的 ```json ... ``` 包裹，避免 JSON 解析失败。
    #>
    param (
        [string]$RawText
    )

    if (Test-StringEmpty -Value $RawText) {
        return $RawText
    }

    $text = $RawText.Trim()
    if ($text.StartsWith('```')) {
        $content = $text.Substring(3).TrimStart()
        $newlineSequence = [System.Environment]::NewLine
        $newlineIndex = $content.IndexOf($newlineSequence)
        $delimiterLength = $newlineSequence.Length
        if ($newlineIndex -lt 0) {
            $newlineIndex = $content.IndexOf([char]10)
            $delimiterLength = 1
        }
        if ($newlineIndex -ge 0) {
            $languageTag = $content.Substring(0, $newlineIndex).Trim()
            if ($languageTag -match '^[a-zA-Z0-9_\-]+$') {
                $content = $content.Substring($newlineIndex + $delimiterLength)
            }
        }
        elseif ($content -match '^[a-zA-Z0-9_\-]+$') {
            $content = ""
        }

        $content = $content.TrimEnd()
        if ($content.EndsWith('```')) {
            $content = $content.Substring(0, $content.Length - 3)
        }

        return $content.Trim()
    }

    return $text
}

function ConvertFrom-AIJsonSafe {
    <#
        .SYNOPSIS
            逐步尝试解析 AI JSON，必要时自动修复反斜杠后再次解析。
    #>
    param (
        [string]$RawText
    )

    if (Test-StringEmpty -Value $RawText) {
        return $null
    }

    $sanitized = Remove-AIResponseCodeFence -RawText $RawText
    if (-not (Test-StringEmpty -Value $sanitized)) {
        $RawText = $sanitized
    }

    if (Test-StringEmpty -Value $RawText) {
        return $null
    }

    try {
        return $RawText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $fixedText = Repair-AIJsonEscapes -RawText $RawText
        if ($fixedText -ne $RawText) {
            try {
                Write-Host "[提示] 检测到 AI 响应存在未转义的反斜杠，已尝试自动修复后重新解析。" -ForegroundColor DarkYellow
                return $fixedText | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw
            }
        }
        throw
    }
}

$script:WindowsAITlsInitialized = $false
function Set-WindowsAITls {
    <#
        .SYNOPSIS
            确保会话启用 TLS1.2 以上，避免旧系统因协议限制导致 HTTPS 请求失败。
    #>
    if ($script:WindowsAITlsInitialized) {
        return
    }

    try {
        $desiredProtocols = [System.Net.SecurityProtocolType]::Tls12
        $protocolNames = [Enum]::GetNames([System.Net.SecurityProtocolType])
        if ($protocolNames -contains 'Tls13') {
            $desiredProtocols = $desiredProtocols -bor ([System.Net.SecurityProtocolType]::Tls13)
        }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor $desiredProtocols
    }
    catch {
        Write-Host "[提示] 无法更新 TLS 设置，继续沿用系统默认配置：$($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    $script:WindowsAITlsInitialized = $true
}

Set-WindowsAITls

function Convert-AIMessageContentToString {
    <#
        .SYNOPSIS
            兼容不同供应商返回的 message.content 结构，将其统一为纯文本字符串。
    #>
    param (
        [object]$Content
    )

    if ($null -eq $Content) {
        return ""
    }

    if ($Content -is [string]) {
        return $Content
    }

    if ($Content -is [System.Collections.IEnumerable]) {
        $builder = [System.Text.StringBuilder]::new()
        foreach ($item in $Content) {
            if ($null -eq $item) {
                continue
            }

            if ($item -is [string]) {
                $builder.Append($item) | Out-Null
                continue
            }

            if ($item -is [pscustomobject]) {
                if ($item.PSObject.Properties['text'] -and $item.text) {
                    $builder.Append($item.text) | Out-Null
                    continue
                }
                if ($item.PSObject.Properties['content'] -and $item.content) {
                    $builder.Append($item.content) | Out-Null
                    continue
                }
                if ($item.PSObject.Properties['value'] -and $item.value) {
                    $builder.Append($item.value) | Out-Null
                    continue
                }
            }
            elseif ($item -is [hashtable] -and $item.ContainsKey('text')) {
                $builder.Append($item['text']) | Out-Null
            }
        }
        return $builder.ToString()
    }

    try {
        return $Content.ToString()
    }
    catch {
        return ""
    }
}

function Invoke-AICall {
    param (
        [string]$UserPrompt,
        [hashtable]$Config,
        [System.Collections.IEnumerable]$ConversationHistory = @()
    )

    if (-not $Config) {
        Write-Host "[错误] 未提供配置对象，无法调用 AI 接口。" -ForegroundColor Red
        return $null
    }

    try {
        $requestUri = [System.Uri]$Config.apiUrl
    }
    catch {
        Write-Host "[错误] 配置的 apiUrl 无法解析为合法地址：$($Config.apiUrl)" -ForegroundColor Red
        return $null
    }

    $useMockMode = $false
    if ($Config.aiProvider -and $Config.aiProvider.ToString().Equals('Mock', [System.StringComparison]::InvariantCultureIgnoreCase)) {
        $useMockMode = $true
    }
    if ($env:WINDOWS_AI_MOCK -and $env:WINDOWS_AI_MOCK -eq '1') {
        $useMockMode = $true
    }

    $systemPrompt = @"
你是一名资深中文问答助手兼Windows PowerShell专家，需要根据用户需求在“命令执行”与“直接回答”之间做出判断，并严格遵守以下规则：

1. **响应格式**：仅返回一个 JSON 对象，必须包含字段：
   - "responseType"：当只需解答问题时写 "answer"，当需要执行命令时写 "commands"。
   - "explanation"：说明你的思路与判断。
   - "answer"：当 responseType 为 "answer" 时，给出详尽中文解答；若非问答，可留空字符串。
   - "commands"：一个数组，数组元素为包含 "command"（PowerShell 指令）与 "effect"（预期效果）的对象；若无需执行命令则返回空数组。
2. **安全策略**：拒绝生成或提示高危命令（如删除系统关键文件、关闭安全机制等），必要时在 "answer" 中解释原因。
3. **可执行性**：所有生成命令必须在标准 Windows PowerShell 中可直接执行，避免伪代码。
4. **上下文记忆**：你会收到先前的用户与助手消息，请结合这些上下文回答问题；当用户追问同一方向的内容时，优先参考历史记录给出准确描述；若确实没有历史，需明确说明。
5. **仅输出 JSON**：禁止输出 Markdown 或额外文本。

如果一件事情可以直接回答也可以使用命令调用windows自带的组件达到效果，请优先填写 "commands" 并让 "answer" 为空
如果用户需要下载，请优先考虑将命令指向官网或者是知名镜像源
"@

    $messages = @(
        @{ role = "system"; content = $systemPrompt }
    )

    $contextLimit = 0
    if ($Config.ContainsKey('maxContextTurns') -and $null -ne $Config.maxContextTurns) {
        try {
            $contextLimit = [int]$Config.maxContextTurns
        }
        catch {
            $contextLimit = 0
        }
    }

    $historyItems = [System.Collections.ArrayList]::new()
    if ($ConversationHistory) {
        foreach ($entry in $ConversationHistory) {
            if (-not $entry) {
                continue
            }
            $null = $historyItems.Add($entry)
        }
    }

    $contextLimit = [Math]::Max(0, $contextLimit)
    $maxHistoryMessages = $contextLimit * 2
    if ($maxHistoryMessages -le 0) {
        $historyItems.Clear()
    }
    else {
        while ($historyItems.Count -gt $maxHistoryMessages) {
            $historyItems.RemoveAt(0)
        }
    }

    $historyCount = $historyItems.Count

    if ($historyCount -gt 0) {
        foreach ($entry in $historyItems) {
            $role = $entry.role
            $content = $entry.content

            if ((Test-StringEmpty -Value $role) -or (Test-StringEmpty -Value $content)) {
                continue
            }

            $messages += @{
                role    = $role
                content = $content
            }
        }
    }

    $messages += @{
        role    = "user"
        content = $UserPrompt
    }

    if ($useMockMode) {
        $mockAnswer = "（测试模式）已接收输入：$UserPrompt"
        if ($historyCount -gt 0) {
            $mockAnswer += "；已附带 $historyCount 条历史消息。"
        }

        return [PSCustomObject]@{
            responseType = 'answer'
            explanation  = '测试模式：未调用真实 API。'
            answer       = $mockAnswer
            commands     = @()
        }
    }

    $bodyTable = @{
        model       = $Config.model
        messages    = $messages
        temperature = 0.2
    }

    if ($Config.ContainsKey('response_format') -and $Config.response_format) {
        $bodyTable.response_format = $Config.response_format
    }

    # 使用 UTF8 编码确保中文正确传输
    $body = $bodyTable | ConvertTo-Json -Depth 10 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $timeoutSeconds = 90
    if ($Config.ContainsKey('requestTimeoutSec') -and $Config.requestTimeoutSec) {
        try {
            $timeoutSeconds = [Math]::Max(10, [int]$Config.requestTimeoutSec)
        }
        catch {
            $timeoutSeconds = 90
        }
    }

    $headers = @{
        Authorization  = "Bearer $($Config.apiKey.Trim())"
        'Content-Type' = 'application/json; charset=utf-8'
        Accept         = 'application/json'
        'User-Agent'   = 'WindowsAI-Assistant/1.0'
    }

    try {
        # 使用 Invoke-WebRequest + RawContentStream，强制按 UTF8 解码可避免响应缺少 charset 时的乱码
        $webResponse = Invoke-WebRequest -Uri $requestUri -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec $timeoutSeconds -ErrorAction Stop
        $rawStream = $webResponse.RawContentStream
        if ($rawStream.CanSeek) {
            $rawStream.Position = 0
        }

        $streamReader = [System.IO.StreamReader]::new($rawStream, [System.Text.Encoding]::UTF8, $true)
        $responseText = $streamReader.ReadToEnd()
        $streamReader.Close()

        try {
            $response = $responseText | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $previewText = "<空响应>"
            if (-not [string]::IsNullOrEmpty($responseText)) {
                $clipLength = [Math]::Min(300, $responseText.Length)
                $previewText = $responseText.Substring(0, $clipLength)
            }
            Write-Host "[错误] AI 返回的内容不是有效 JSON，原始片段：$previewText" -ForegroundColor Red
            throw
        }

        if (-not $response.choices -or $response.choices.Count -eq 0) {
            throw "AI 未返回任何结果"
        }

        $rawContent = $response.choices[0].message.content
        if (-not $rawContent) {
            throw "AI 响应内容为空"
        }
        $normalizedContent = Convert-AIMessageContentToString -Content $rawContent
        if (Test-StringEmpty -Value $normalizedContent) {
            throw "AI 响应内容为空"
        }
        $aiResponseContent = ConvertFrom-AIJsonSafe -RawText $normalizedContent
        return $aiResponseContent
    }
    catch {
        Write-Host "[错误] 调用 AI API 失败，请检查网络与 API 配置。" -ForegroundColor Red
        Write-Host "[详细错误] $($_.Exception.Message)" -ForegroundColor DarkRed

        $httpError = Format-HttpError -Exception $_.Exception
        if ($httpError.StatusCode) {
            Write-Host "[HTTP状态码] $($httpError.StatusCode)" -ForegroundColor DarkRed
        }

        if ($httpError.Body) {
            Write-Host "[API返回] $($httpError.Body)" -ForegroundColor DarkRed
        }
        elseif ($httpError.StatusCode) {
            Write-Host "[无法读取API错误详情]" -ForegroundColor DarkRed
        }

        return $null
    }
}
