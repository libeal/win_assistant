# modules/logger.ps1

# 模块内部使用的共享状态
$script:SessionLog = $null
$script:LogDirectory = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "logs"

function Initialize-SessionLog {
    # 在会话开始时调用，初始化日志结构
    if (-not (Test-Path -Path $script:LogDirectory)) {
        New-Item -Path $script:LogDirectory -ItemType Directory | Out-Null
    }

    $script:SessionLog = @{
        StartTime    = Get-Date
        EndTime      = $null
        Interactions = New-Object System.Collections.ArrayList
    }
}

function Add-LogEntry {
    # 在每次用户交互后调用，记录详情
    param (
        [string]$UserInput,
        [object]$AIResponse,       # 来自AI的原始响应
        [object]$ExecutionResults  # 来自执行器模块的执行结果
    )

    if (-not $script:SessionLog) {
        Initialize-SessionLog
    }

    $aiExplanation = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'explanation' -Default '（AI 未提供解释）' -TreatEmptyStringAsNull
    $aiAnswer = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'answer' -Default '' -TreatEmptyStringAsNull
    $responseType = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'responseType' -Default 'commands' -TreatEmptyStringAsNull

    $interaction = @{
        Timestamp        = Get-Date
        UserPrompt       = $UserInput
        AIExplanation    = $aiExplanation
        ResponseType     = $responseType
        AIAnswer         = $aiAnswer
        ProposedCommands = New-Object System.Collections.ArrayList
        ExecutionSteps   = New-Object System.Collections.ArrayList
    }

    $commandItems = Get-AIResponseCommands -AIResponse $AIResponse
    if ($commandItems.Count -gt 0) {
        foreach ($command in $commandItems) {
            $null = $interaction.ProposedCommands.Add(@{
                    Command = $command.command
                    Effect  = $command.effect
                })
        }
    }

    if (-not $ExecutionResults) {
        $ExecutionResults = @()
    }

    foreach ($result in $ExecutionResults) {
        if (-not $result) {
            continue
        }

        $outputText = ""
        $errorDetails = ""
        if ($result.PSObject.Properties.Name -contains 'CommandOutput' -and
            -not (Test-StringEmpty -Value $result.CommandOutput)) {
            $outputText = $result.CommandOutput
        }
        if ($result.PSObject.Properties.Name -contains 'ErrorDetails' -and
            -not (Test-StringEmpty -Value $result.ErrorDetails)) {
            $errorDetails = $result.ErrorDetails
        }

        $backups = @()
        if ($result.PSObject.Properties.Name -contains 'Backups' -and $result.Backups) {
            $backups = @($result.Backups)
        }

        $null = $interaction.ExecutionSteps.Add(@{
                Command        = $result.Command
                IntendedEffect = $result.IntendedEffect
                UserChoice     = $result.UserChoice
                FinalStatus    = $result.FinalStatus
                CommandOutput  = $outputText
                ErrorDetails   = $errorDetails
                Backups        = $backups
            })
    }

    $null = $script:SessionLog.Interactions.Add($interaction)
}

function Export-SessionLogToMarkdown {
    # 在会话结束时调用，生成并保存MD文件
    if (-not $script:SessionLog) {
        Write-Host "[日志] 当前会话未记录任何数据，跳过日志导出。" -ForegroundColor Yellow
        return
    }

    $logData = $script:SessionLog
    $logData.EndTime = Get-Date

    # 生成唯一的文件名，例如: SessionLog_2023-10-27_15-30-00.md
    $fileName = "SessionLog_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').md"
    $filePath = Join-Path -Path $script:LogDirectory -ChildPath $fileName

    # 使用 StringBuilder 高效构建字符串
    $sb = [System.Text.StringBuilder]::new()
    
    $sb.AppendLine("# Windows AI 助手会话日志") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("- **开始时间:** $($logData.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))") | Out-Null
    $sb.AppendLine("- **结束时间:** $($logData.EndTime.ToString('yyyy-MM-dd HH:mm:ss'))") | Out-Null
    $sb.AppendLine("- **总计交互:** $($logData.Interactions.Count) 次") | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("---") | Out-Null
    $sb.AppendLine("") | Out-Null

    if ($logData.Interactions.Count -gt 0) {
        $sb.AppendLine("## 交互详情") | Out-Null
        $sb.AppendLine("") | Out-Null

        for ($i = 0; $i -lt $logData.Interactions.Count; $i++) {
            $interaction = $logData.Interactions[$i]
            $sb.AppendLine("### 交互 #$($i + 1)") | Out-Null
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("**时间:** $($interaction.Timestamp.ToString('HH:mm:ss'))") | Out-Null
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("> **用户输入:** $($interaction.UserPrompt)") | Out-Null
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("**AI 计划:** $($interaction.AIExplanation)") | Out-Null
            $sb.AppendLine("") | Out-Null
            $sb.AppendLine("**响应类型:** $($interaction.ResponseType)") | Out-Null
            $sb.AppendLine("") | Out-Null

            if ($interaction.AIAnswer) {
                $sb.AppendLine("**AI 回答:**") | Out-Null
                $sb.AppendLine("") | Out-Null
                $sb.AppendLine("> $($interaction.AIAnswer)") | Out-Null
                $sb.AppendLine("") | Out-Null
            }

            if ($interaction.ProposedCommands.Count -gt 0) {
                $sb.AppendLine("**AI 生成的命令:**") | Out-Null
                foreach ($command in $interaction.ProposedCommands) {
                    $sb.AppendLine("- ``$($command.Command)`` -> $($command.Effect)") | Out-Null
                }
                $sb.AppendLine("") | Out-Null
            }

            if ($interaction.ExecutionSteps.Count -gt 0) {
                $sb.AppendLine("**执行步骤:**") | Out-Null
                foreach ($step in $interaction.ExecutionSteps) {
                    $sb.AppendLine("- **命令:**") | Out-Null
                    $sb.AppendLine("  ``````powershell") | Out-Null
                    $sb.AppendLine("  $($step.Command)") | Out-Null
                    $sb.AppendLine("  ``````") | Out-Null
                    $sb.AppendLine("  - **预期效果:** $($step.IntendedEffect)") | Out-Null
                    $sb.AppendLine("  - **用户决定:** $($step.UserChoice)") | Out-Null
                    $sb.AppendLine("  - **最终状态:** $($step.FinalStatus)") | Out-Null
                    if ($step.CommandOutput) {
                        $sb.AppendLine("  - **输出:**") | Out-Null
                        $sb.AppendLine("    ``````") | Out-Null
                        foreach ($line in ($step.CommandOutput -split "`r?`n")) {
                            $sb.AppendLine("    $line") | Out-Null
                        }
                        $sb.AppendLine("    ``````") | Out-Null
                    }
                    if ($step.Backups -and $step.Backups.Count -gt 0) {
                        $sb.AppendLine("  - **备份:**") | Out-Null
                        foreach ($backup in $step.Backups) {
                            if (-not $backup) {
                                continue
                            }
                            $backupPath = $backup.BackupFile
                            $sourcePath = $backup.TargetFile
                            $timeText = ""
                            if ($backup.PSObject.Properties.Name -contains 'Timestamp' -and $backup.Timestamp) {
                                $timeText = " @ $($backup.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))"
                            }
                            $sb.AppendLine("    - $sourcePath -> $backupPath$timeText") | Out-Null
                        }
                    }
                    if ($step.ErrorDetails) {
                        $sb.AppendLine("  - **错误详情:** $($step.ErrorDetails)") | Out-Null
                    }
                    $sb.AppendLine("") | Out-Null
                }
            }
            else {
                $sb.AppendLine("**执行步骤:** 无需执行任何命令。") | Out-Null
                $sb.AppendLine("") | Out-Null
            }
            $sb.AppendLine("---") | Out-Null
            $sb.AppendLine("") | Out-Null
        }
    }

    try {
        Set-Content -Path $filePath -Value $sb.ToString() -Encoding UTF8
        Write-Host "`n[日志] 会话日志已保存至: $filePath" -ForegroundColor Green
    }
    catch {
        Write-Host "`n[错误] 保存日志文件失败: $_" -ForegroundColor Red
    }
}
