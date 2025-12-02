# modules/executor.ps1
function Invoke-CommandExecution {
    param (
        [object]$AIResponse
    )

    $planSummary = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'explanation' -Default "AI 未提供计划说明" -TreatEmptyStringAsNull
    Write-Host "`n[AI] 计划概述：$planSummary" -ForegroundColor Yellow

    $responseType = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'responseType' -Default "commands" -TreatEmptyStringAsNull
    if ($responseType -isnot [string]) {
        $responseType = "commands"
    }
    else {
        $responseType = $responseType.ToLowerInvariant()
    }

    $assistantReply = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'answer' -Default "" -TreatEmptyStringAsNull

    if (-not (Test-StringEmpty -Value $assistantReply)) {
        Write-Host "`n[AI 回答] $assistantReply" -ForegroundColor Cyan
    }

    $executionResults = @()

    $commands = Get-AIResponseCommands -AIResponse $AIResponse

    if ($responseType -eq 'answer') {
        if ($commands -and $commands.Count -gt 0) {
            Write-Host "[警告] AI 声称只需回答却仍附带命令，已忽略这些命令以保障安全。" -ForegroundColor Yellow
        }
        else {
            Write-Host "[提示] AI 判断本次仅需问答，无需执行任何命令。" -ForegroundColor DarkYellow
        }
        return $executionResults
    }

    if (-not $commands -or $commands.Count -eq 0) {
        Write-Host "[提示] 本次没有需要执行的命令。" -ForegroundColor DarkYellow
        return $executionResults
    }

    foreach ($cmd in $commands) {
        if (-not $cmd -or (Test-StringEmpty -Value $cmd.command)) {
            Write-Host "[跳过] AI 返回了格式不完整的命令条目，已忽略。" -ForegroundColor Yellow
            continue
        }

        Write-Host "`n----------------------------------------------" -ForegroundColor White
        Write-Host "准备执行的命令：" -ForegroundColor Magenta
        Write-Host $cmd.command -ForegroundColor White

        Write-Host "`n预期效果：" -ForegroundColor Magenta
        if ($cmd.effect) {
            Write-Host $cmd.effect -ForegroundColor Cyan
        }
        else {
            Write-Host "（AI 未提供预期效果描述）" -ForegroundColor DarkCyan
        }
        
        $choice = ""
        while ($choice -notin @('Y', 'N')) {
            $choice = Read-Host "是否执行此命令？(Y/N)"
            $choice = $choice.ToUpper()
        }

        $status = ""
        $backupSummary = @()
        $capturedOutputText = ""
        $errorDetails = ""
        if ($choice -eq 'Y') {
            $backupContext = Invoke-BackupSelection -CommandText $cmd.command
            $backupSummary = $backupContext.Backups
            if ($backupContext.ShouldAbort) {
                $status = "用户取消执行"
                Write-Host "[提示] 用户取消执行，命令已跳过。" -ForegroundColor Yellow
            }
            else {
                $previousPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Stop'
                $localInvokeErrors = @()
                $invocationSucceeded = $false
                try {
                    $commandOutput = @(Invoke-Expression -ErrorVariable +localInvokeErrors $cmd.command)
                    if ($commandOutput.Count -gt 0) {
                        Write-Host "`n[命令输出]" -ForegroundColor DarkGray
                        $commandOutput | Out-Host
                        Write-Host ""
                        $consoleWidth = 200
                        if ($Host -and $Host.UI -and $Host.UI.RawUI -and $Host.UI.RawUI.BufferSize.Width) {
                            $consoleWidth = [Math]::Max(40, $Host.UI.RawUI.BufferSize.Width)
                        }
                        $capturedOutputText = ($commandOutput | Out-String -Width $consoleWidth).TrimEnd()
                    }
                    $invocationSucceeded = $true
                }
                catch {
                    $errorDetails = $_.Exception.Message
                    $invocationSucceeded = $false
                }
                finally {
                    $ErrorActionPreference = $previousPreference
                }

                if ($localInvokeErrors.Count -gt 0) {
                    $invocationSucceeded = $false
                    if (Test-StringEmpty -Value $errorDetails) {
                        $errorMessages = New-Object System.Collections.Generic.List[string]
                        foreach ($record in $localInvokeErrors) {
                            $message = $null
                            if ($record.Exception -and -not [string]::IsNullOrWhiteSpace($record.Exception.Message)) {
                                $message = $record.Exception.Message.Trim()
                            }
                            elseif ($record.ToString()) {
                                $message = $record.ToString().Trim()
                            }

                            if (-not (Test-StringEmpty -Value $message) -and -not $errorMessages.Contains($message)) {
                                $null = $errorMessages.Add($message)
                            }
                        }

                        if ($errorMessages.Count -gt 0) {
                            $errorDetails = ($errorMessages -join '; ')
                        }
                    }
                }

                if ($invocationSucceeded) {
                    $status = "执行成功"
                    Write-Host "[完成] 命令已执行。" -ForegroundColor Green
                }
                else {
                    if (Test-StringEmpty -Value $errorDetails) {
                        $errorDetails = "命令执行失败，但未能获取详细错误信息。"
                    }
                    $status = "失败：$errorDetails"
                    Write-Host "[错误] 命令执行失败：$errorDetails" -ForegroundColor Red
                }
            }
        }
        else {
            $status = "用户跳过"
            Write-Host "[跳过] 已取消执行。" -ForegroundColor Yellow
        }

        $executionResults += [PSCustomObject]@{
            Command        = $cmd.command
            IntendedEffect = $cmd.effect
            UserChoice     = $choice
            FinalStatus    = $status
            Backups        = $backupSummary
            CommandOutput  = $capturedOutputText
            ErrorDetails   = $errorDetails
        }
    }
    Write-Host "`n----------------------------------------------" -ForegroundColor White

    return $executionResults
}
