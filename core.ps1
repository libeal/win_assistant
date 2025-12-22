# core.ps1
# Windows AI 助理主流程：加载模块、读取配置、循环交互
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "common.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "backup.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "personalization.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "attachments.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "mcp.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "ai-api.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "executor.psm1") -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path "$PSScriptRoot\modules" -ChildPath "logger.psm1") -Force -DisableNameChecking

#虽然这里是这么写，但是这是为了向下兼容，如果高版本可以换 `ConvertFrom-Json -AsHashtable`
$conversationHistory = New-Object System.Collections.ArrayList

function Get-AssistantConversationSummary {
    param (
        [object]$AIResponse,
        [object]$ExecutionResults
    )

    $segments = New-Object System.Collections.ArrayList

    $planSummary = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'explanation' -Default $null -TreatEmptyStringAsNull
    if (-not (Test-StringEmpty -Value $planSummary)) {
        $segments.Add("计划: $planSummary") | Out-Null
    }

    $answerText = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'answer' -Default $null -TreatEmptyStringAsNull
    if (-not (Test-StringEmpty -Value $answerText)) {
        $segments.Add("回答: $answerText") | Out-Null
    }

    $commands = Get-AIResponseCommands -AIResponse $AIResponse
    if ($commands.Count -gt 0) {
        $segments.Add("命令列表:") | Out-Null
        foreach ($command in $commands) {
            $cmdText = $command.command
            $effectText = $command.effect
            if (Test-StringEmpty -Value $effectText) {
                $effectText = "（未提供预期效果）"
            }
            $segments.Add("- $cmdText -> $effectText") | Out-Null
        }
    }

    if ($ExecutionResults) {
        $segments.Add("执行结果:") | Out-Null
        foreach ($result in $ExecutionResults) {
            if (-not $result) {
                continue
            }

            $statusLine = "- $($result.Command) => $($result.FinalStatus)"
            if ($result.UserChoice) {
                $statusLine += "（用户选择: $($result.UserChoice)）"
            }
            $segments.Add($statusLine) | Out-Null

            if ($result.PSObject.Properties.Name -contains 'ErrorDetails' -and
                -not (Test-StringEmpty -Value $result.ErrorDetails)) {
                $segments.Add("错误详情: $($result.ErrorDetails)") | Out-Null
            }

            # 将 MCP 调用输出摘要写入上下文，便于模型在下一轮继续推理
            $isMcpCommand = $false
            try {
                if ($result.Command -and ($result.Command -match '\binvoke-mcprequest\b')) {
                    $isMcpCommand = $true
                }
            }
            catch {
                $isMcpCommand = $false
            }

            if ($isMcpCommand -and
                $result.PSObject.Properties.Name -contains 'CommandOutput' -and
                -not (Test-StringEmpty -Value $result.CommandOutput)) {
                $maxLen = 1200
                $outputText = $result.CommandOutput.Trim()
                if ($outputText.Length -gt $maxLen) {
                    $outputText = $outputText.Substring(0, $maxLen) + '...（输出已截断）'
                }
                $segments.Add("MCP 输出摘要: $outputText") | Out-Null
            }
        }
    }

    if ($segments.Count -eq 0) {
        try {
            return ($AIResponse | ConvertTo-Json -Depth 10 -Compress)
        }
        catch {
            return [string]$AIResponse
        }
    }

    return ($segments -join "`n")
}

function New-ConversationEntry {
    param (
        [string]$Role,
        [string]$Content
    )

    if ((Test-StringEmpty -Value $Role) -or (Test-StringEmpty -Value $Content)) {
        return $null
    }

    return [PSCustomObject]@{
        role    = $Role
        content = $Content
    }
}

function Update-ConversationHistory {
    param (
        [System.Collections.ArrayList]$History,
        [string]$UserMessage,
        [object]$AIResponse,
        [object]$ExecutionResults,
        [int]$MaxTurns
    )

    if ($null -eq $History) {
        return
    }

    $maxTurnsNormalized = 0
    try {
        $maxTurnsNormalized = [Math]::Max(0, [int]$MaxTurns)
    }
    catch {
        $maxTurnsNormalized = 0
    }

    if ($maxTurnsNormalized -le 0) {
        $History.Clear()
        return
    }

    $userEntry = New-ConversationEntry -Role 'user' -Content $UserMessage
    if ($userEntry) {
        $null = $History.Add($userEntry)
    }

    $assistantContent = Get-AssistantConversationSummary -AIResponse $AIResponse -ExecutionResults $ExecutionResults
    $assistantEntry = New-ConversationEntry -Role 'assistant' -Content $assistantContent
    if ($assistantEntry) {
        $null = $History.Add($assistantEntry)
    }

    $maxMessages = $maxTurnsNormalized * 2
    while ($History.Count -gt $maxMessages) {
        $History.RemoveAt(0)
    }
}

$configPath = "$PSScriptRoot\config.json"
try {
    $config = Import-WindowsAIConfig -ConfigPath $configPath
}
catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host $_.Exception.InnerException.Message -ForegroundColor DarkRed
    }
    exit 1
}

$mcpConfig = Import-McpConfig
$null = Initialize-McpRegistry -McpConfig $mcpConfig

$maxContextTurns = $config.maxContextTurns

Initialize-SessionLog
Write-Host "[日志] 会话已就绪，所有操作都会被保存。" -ForegroundColor Gray

while ($true) {
    Write-Host "`n==============================================" -ForegroundColor Cyan
    Write-Host "Windows AI 助理已待命，可直接输入需求；输入 'exit' 结束会话。" -ForegroundColor Green
    Write-Host ""
    $userInput = Read-Host "请问有什么需要"

    if ($userInput -eq 'exit') {
        Export-SessionLogToMarkdown
        Write-Host "期待你的下一次使用。" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        break
    }

    if (Test-StringEmpty -Value $userInput) {
        continue
    }

    $attachmentCommandPattern = '^\s*(Add-AIAttachment|Clear-PendingAIAttachments|Get-PendingAIAttachments)\b'
    if ($userInput -match $attachmentCommandPattern) {
        Write-Host "[本地执行] 检测到附件管理命令，直接在本地运行，不会发送给 AI。" -ForegroundColor DarkYellow
        try {
            $localOutput = @(Invoke-Expression $userInput)
            if ($localOutput.Count -gt 0) {
                Write-Host "`n[命令输出]" -ForegroundColor DarkGray
                $localOutput | Out-Host
            }
        }
        catch {
            Write-Host "[错误] 本地执行失败：$($_.Exception.Message)" -ForegroundColor Red
        }
        continue
    }

    Write-Host "`n[AI] 正在思考方案..." -ForegroundColor Gray
    $conversationMessages = @()
    if ($maxContextTurns -gt 0 -and $conversationHistory.Count -gt 0) {
        $conversationMessages = $conversationHistory.ToArray()
    }

    $defaultUserPromptSuffix = @"
（注意响应格式要求，按照要求返回json数据）
"@.Trim()

    $userPromptSuffix = $null
    try {
        if ($config -is [hashtable]) {
            if ($config.ContainsKey('userPromptSuffix') -and -not (Test-StringEmpty -Value ([string]$config['userPromptSuffix']))) {
                $userPromptSuffix = [string]$config['userPromptSuffix']
            }
        }
        elseif ($config -and $config.PSObject.Properties['userPromptSuffix']) {
            if (-not (Test-StringEmpty -Value ([string]$config.userPromptSuffix))) {
                $userPromptSuffix = [string]$config.userPromptSuffix
            }
        }
    }
    catch {
        $userPromptSuffix = $null
    }

    if (Test-StringEmpty -Value $userPromptSuffix) {
        $userPromptSuffix = $defaultUserPromptSuffix
    }

    $userPromptForAI = $userInput
    if (-not (Test-StringEmpty -Value $userPromptSuffix)) {
        $userPromptForAI = $userInput + "`n`n" + $userPromptSuffix
    }

    $aiResult = Invoke-AICall -UserPrompt $userPromptForAI -Config $config -ConversationHistory $conversationMessages

    if ($null -eq $aiResult) {
        Write-Host "[错误] AI 没有返回结果或返回的结果不符合要求，请重试或检查配置。" -ForegroundColor Red
        continue
    }

    $executionResults = Invoke-CommandExecution -AIResponse $aiResult
    Add-LogEntry -UserInput $userInput -AIResponse $aiResult -ExecutionResults $executionResults
    Update-ConversationHistory -History $conversationHistory -UserMessage $userInput -AIResponse $aiResult -ExecutionResults $executionResults -MaxTurns $maxContextTurns
}
