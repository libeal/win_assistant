# modules/executor.ps1
function Convert-CommandOutputForLog {
    param (
        [object[]]$OutputItems
    )

    if (-not $OutputItems -or $OutputItems.Count -eq 0) {
        return ""
    }

    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($item in $OutputItems) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [string]) {
            $text = $item.TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $segments.Add($text) | Out-Null
            }
            continue
        }

        try {
            $jsonText = $item | ConvertTo-Json -Depth 10 -Compress
            if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
                $segments.Add($jsonText) | Out-Null
                continue
            }
        }
        catch {
        }

        try {
            $fallback = ($item | Out-String).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($fallback)) {
                $segments.Add($fallback) | Out-Null
            }
        }
        catch {
            $segments.Add($item.ToString()) | Out-Null
        }
    }

    if ($segments.Count -eq 0) {
        return ""
    }

    $joined = ($segments -join "`n").Trim()
    $maxLength = 6000
    if ($joined.Length -gt $maxLength) {
        $joined = $joined.Substring(0, $maxLength)
    }
    return $joined
}

function Add-UniqueStringValue {
    param (
        [System.Collections.Generic.List[string]]$Target,
        [string]$Value
    )

    if (-not $Target -or (Test-StringEmpty -Value $Value)) {
        return
    }

    $normalized = $Value.Trim()
    if (-not (Test-StringEmpty -Value $normalized) -and -not $Target.Contains($normalized)) {
        $null = $Target.Add($normalized)
    }
}

function Convert-ErrorRecordMessages {
    param (
        [System.Collections.IEnumerable]$ErrorRecords
    )

    if (-not $ErrorRecords) {
        return ""
    }

    $messages = New-Object System.Collections.Generic.List[string]
    foreach ($record in $ErrorRecords) {
        if (-not $record) {
            continue
        }

        $message = $null
        if ($record.Exception -and -not [string]::IsNullOrWhiteSpace($record.Exception.Message)) {
            $message = $record.Exception.Message.Trim()
        }
        elseif ($record.ToString()) {
            $message = $record.ToString().Trim()
        }

        if (-not (Test-StringEmpty -Value $message) -and -not $messages.Contains($message)) {
            $null = $messages.Add($message)
        }
    }

    if ($messages.Count -eq 0) {
        return ""
    }

    return $messages -join '; '
}

function ConvertTo-SimpleHashtable {
    param (
        [object]$InputObject
    )

    if (-not $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        return $InputObject
    }

    if ($InputObject -is [pscustomobject]) {
        $table = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $table[$prop.Name] = $prop.Value
        }
        return $table
    }

    return $null
}

function Expand-CommandOutputItems {
    param (
        [object[]]$Items
    )

    $flatItems = New-Object System.Collections.Generic.List[object]

    if (-not $Items) {
        return $flatItems
    }

    foreach ($item in $Items) {
        if ($null -eq $item) {
            continue
        }

        $itemType = $item.GetType()
        if ($itemType.IsArray -or $item -is [System.Collections.IList]) {
            foreach ($child in $item) {
                if ($null -ne $child) {
                    $flatItems.Add($child) | Out-Null
                }
            }
            continue
        }

        $flatItems.Add($item) | Out-Null
    }

    return $flatItems
}

function Invoke-CommandAndCapture {
    param (
        [string]$CommandText
    )

    $result = [PSCustomObject]@{
        OutputItems  = @()
        Succeeded    = $false
        ErrorDetails = ""
        InvokeErrors = @()
    }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $localInvokeErrors = @()
    try {
        $result.OutputItems = @(Invoke-Expression -ErrorVariable +localInvokeErrors $CommandText)
        $result.Succeeded = $true
    }
    catch {
        $result.ErrorDetails = $_.Exception.Message
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $result.InvokeErrors = $localInvokeErrors

    if ($localInvokeErrors.Count -gt 0) {
        $result.Succeeded = $false
        if (Test-StringEmpty -Value $result.ErrorDetails) {
            $result.ErrorDetails = Convert-ErrorRecordMessages -ErrorRecords $localInvokeErrors
        }
    }

    return $result
}

function Get-McpOutputAnalysis {
    param (
        [object[]]$CommandOutput
    )

    $result = [PSCustomObject]@{
        ContainsMcpResult = $false
        AllSucceeded      = $true
        Errors            = New-Object System.Collections.Generic.List[string]
        Warnings          = New-Object System.Collections.Generic.List[string]
    }

    if (-not $CommandOutput -or $CommandOutput.Count -eq 0) {
        return $result
    }

    $flatItems = Expand-CommandOutputItems -Items $CommandOutput

    foreach ($item in $flatItems) {
        $candidate = ConvertTo-SimpleHashtable -InputObject $item
        if (-not $candidate) {
            continue
        }

        $hasSuccessProperty = $candidate.ContainsKey('success')
        $servicePresent = $candidate.ContainsKey('service') -and -not (Test-StringEmpty -Value ([string]$candidate['service']))
        $transportPresent = $candidate.ContainsKey('transport') -and -not (Test-StringEmpty -Value ([string]$candidate['transport']))
        $typeValue = $null
        if ($candidate.ContainsKey('type')) {
            $typeValue = [string]$candidate['type']
        }

        $hasMcpMarkers = $servicePresent -or $transportPresent -or ($typeValue -and $typeValue -like 'mcp*')
        $looksLikeMcp = $hasSuccessProperty -and $hasMcpMarkers

        if (-not $looksLikeMcp) {
            continue
        }

        $result.ContainsMcpResult = $true

        if ($candidate.ContainsKey('warnings')) {
            $warningValue = $candidate['warnings']
            if ($warningValue -is [System.Collections.IEnumerable] -and -not ($warningValue -is [string])) {
                foreach ($warning in $warningValue) {
                    Add-UniqueStringValue -Target $result.Warnings -Value ([string]$warning)
                }
            }
            else {
                Add-UniqueStringValue -Target $result.Warnings -Value ([string]$warningValue)
            }
        }

        $successValue = $true
        if ($hasSuccessProperty) {
            $successValue = [bool]$candidate['success']
        }

        $errorTexts = New-Object System.Collections.Generic.List[string]

        if ($candidate.ContainsKey('error')) {
            Add-UniqueStringValue -Target $errorTexts -Value ([string]$candidate['error'])
        }

        if ($candidate.ContainsKey('errors')) {
            $errorsCollection = $candidate['errors']
            if ($errorsCollection -is [System.Collections.IEnumerable] -and -not ($errorsCollection -is [string])) {
                foreach ($errorItem in $errorsCollection) {
                    Add-UniqueStringValue -Target $errorTexts -Value ([string]$errorItem)
                }
            }
            else {
                Add-UniqueStringValue -Target $errorTexts -Value ([string]$errorsCollection)
            }
        }

        if (-not $successValue -or $errorTexts.Count -gt 0) {
            $result.AllSucceeded = $false
            foreach ($text in $errorTexts) {
                Add-UniqueStringValue -Target $result.Errors -Value $text
            }
        }
    }

    return $result
}

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

        $mcpMethod = $null
        $mcpService = $null
        try {
            if ($cmd.command -match '\binvoke-mcprequest\b') {
                if ($cmd.command -match '-Method\s+["'']([^"'']+)["'']') {
                    $mcpMethod = $Matches[1]
                }
                if ($cmd.command -match '-Service\s+["'']([^"'']+)["'']') {
                    $mcpService = $Matches[1]
                }
                if (-not $mcpService) {
                    $mcpService = Get-McpDefaultServiceName
                }
                if ($mcpMethod) {
                    $timeoutHint = $null
                    try {
                        $serviceConfig = Get-McpService -Name $mcpService
                        if ($serviceConfig -and $serviceConfig.timeout) {
                            $timeoutHint = $serviceConfig.timeout
                        }
                    }
                    catch {
                        $timeoutHint = $null
                    }
                    $serviceLabel = if ($mcpService) { $mcpService } else { '<默认>' }
                    $timeoutText = if ($timeoutHint) { "，预计超时 ${timeoutHint} 秒" } else { "" }
                    Write-Host "[MCP] 即将调用 $serviceLabel.$mcpMethod$timeoutText（按 q 可中断流式输出）" -ForegroundColor DarkCyan
                }
            }
        }
        catch {
        }

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

        $resultRecord = [PSCustomObject]@{
            Command        = $cmd.command
            IntendedEffect = $cmd.effect
            UserChoice     = $choice
            FinalStatus    = ""
            Backups        = @()
            CommandOutput  = ""
            ErrorDetails   = ""
        }

        if ($choice -ne 'Y') {
            $resultRecord.FinalStatus = "用户跳过"
            Write-Host "[跳过] 已取消执行。" -ForegroundColor Yellow
            $executionResults += $resultRecord
            continue
        }

        $backupContext = Invoke-BackupSelection -CommandText $cmd.command
        $resultRecord.Backups = $backupContext.Backups

        if ($backupContext.ShouldAbort) {
            $resultRecord.FinalStatus = "用户取消执行"
            Write-Host "[提示] 用户取消执行，命令已跳过。" -ForegroundColor Yellow
            $executionResults += $resultRecord
            continue
        }

        $invocationOutcome = Invoke-CommandAndCapture -CommandText $cmd.command

        if ($invocationOutcome.OutputItems.Count -gt 0) {
            Write-Host "`n[命令输出]" -ForegroundColor DarkGray
            $invocationOutcome.OutputItems | Out-Host
            Write-Host ""
            $resultRecord.CommandOutput = Convert-CommandOutputForLog -OutputItems $invocationOutcome.OutputItems
        }

        $invocationSucceeded = $invocationOutcome.Succeeded
        $errorDetails = $invocationOutcome.ErrorDetails

        $mcpAnalysis = Get-McpOutputAnalysis -CommandOutput $invocationOutcome.OutputItems

        if ($mcpAnalysis.ContainsMcpResult) {
            if ($mcpAnalysis.Warnings.Count -gt 0) {
                $warningSummary = $mcpAnalysis.Warnings -join '; '
                if (-not (Test-StringEmpty -Value $warningSummary)) {
                    Write-Host "[MCP 警告] $warningSummary" -ForegroundColor DarkYellow
                }
            }

            if (-not $mcpAnalysis.AllSucceeded) {
                $invocationSucceeded = $false
                if (Test-StringEmpty -Value $errorDetails) {
                    if ($mcpAnalysis.Errors.Count -gt 0) {
                        $errorDetails = "MCP 返回错误：" + ($mcpAnalysis.Errors -join '; ')
                    }
                    else {
                        $errorDetails = "MCP 返回失败结果。"
                    }
                }
            }
        }

        if (-not $invocationSucceeded) {
            if (Test-StringEmpty -Value $errorDetails) {
                $errorDetails = "命令执行失败，但未能获取详细错误信息。"
            }

            $resultRecord.ErrorDetails = $errorDetails
            $resultRecord.FinalStatus = "失败：$errorDetails"
            Write-Host "[错误] 命令执行失败：$errorDetails" -ForegroundColor Red
            $executionResults += $resultRecord
            continue
        }

        $resultRecord.FinalStatus = "执行成功"
        Write-Host "[完成] 命令已执行。" -ForegroundColor Green
        $executionResults += $resultRecord
    }
    Write-Host "`n----------------------------------------------" -ForegroundColor White

    return $executionResults
}

Export-ModuleMember -Function Invoke-CommandExecution,Invoke-CommandAndCapture
