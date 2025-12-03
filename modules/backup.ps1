# modules/backup.ps1

<#
    为潜在的文件/目录写入命令提供可选备份。脚本会解析命令中的路径，
    在真正执行之前让用户决定是否创建同目录压缩备份。
#>

function Test-CommandRequiresBackupPrompt {
    <#
        .SYNOPSIS
            判断命令是否存在写入/删除风险，需要触发备份提示。
    #>
    param (
        [string]$CommandText
    )

    if (Test-StringEmpty -Value $CommandText) {
        return $false
    }

    $normalized = $CommandText.ToLowerInvariant()

    $skipKeywords = @(
        'compress-archive',
        'new-pathbackuparchive'
    )

    foreach ($keyword in $skipKeywords) {
        if ($normalized.Contains($keyword)) {
            return $false
        }
    }

    $dangerPatterns = @(
        '\bremove-item\b',
        '\bdel\b',
        '\berase\b',
        '\brm\b',
        '\brd\b',
        '\brmdir\b',
        '\bset-content\b',
        '\badd-content\b',
        '\bclear-content\b',
        '\bout-file\b',
        '\bset-item\b',
        '\bcopy-item\b',
        '\bmove-item\b',
        '\brename-item\b',
        '\bmklink\b',
        '\bformat-(drive|volume|fs)\b'
    )

    foreach ($pattern in $dangerPatterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    if ($CommandText -match '>>' -or $CommandText -match '>\s*[^>]{1}') {
        return $true
    }

    return $false
}

function Expand-CommandPathVariables {
    param (
        [string]$Candidate
    )

    if (Test-StringEmpty -Value $Candidate) {
        return $Candidate
    }

    return [regex]::Replace($Candidate, '\$env:([A-Za-z0-9_]+)', {
            param($match)
            $name = $match.Groups[1].Value
            $value = [System.Environment]::GetEnvironmentVariable($name)
            if (Test-StringEmpty -Value $value) {
                return $match.Value
            }

            return $value
        })
}

function Convert-PathToken {
    param (
        [string]$Value
    )

    if (Test-StringEmpty -Value $Value) {
        return ""
    }

    return $Value.Trim('"', "'").Trim()
}

function Get-CommandPathCandidates {
    <#
        .SYNOPSIS
            从命令字符串中提取可能的路径片段，去重后返回。
    #>
    param (
        [string]$CommandText
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    if (Test-StringEmpty -Value $CommandText) {
        return $candidates
    }

    $registerCandidate = {
        param($value)
        $normalized = Convert-PathToken -Value $value
        if (Test-StringEmpty -Value $normalized) {
            return
        }
        if ($seen.Add($normalized)) {
            $null = $candidates.Add($normalized)
        }
    }

    try {
        $errors = $null
        $tokens = [System.Management.Automation.PSParser]::Tokenize($CommandText, [ref]$errors)
        $skipValueParameters = @('-filter', '-include', '-exclude', '-filefilter', '-name')
        $waitForValue = $false

        foreach ($token in $tokens) {
            switch ($token.Type) {
                ([System.Management.Automation.PSTokenType]::CommandParameter) {
                    $parameterName = $token.Content.ToLowerInvariant()
                    $waitForValue = $skipValueParameters -contains $parameterName
                    break
                }
                ([System.Management.Automation.PSTokenType]::String) {
                    if ($waitForValue) {
                        $waitForValue = $false
                        break
                    }
                    $value = Convert-PathToken -Value $token.Content
                    if (Test-StringEmpty -Value $value) {
                        break
                    }
                    if ($value -match '[\\/:]' -or
                        $value.StartsWith('.') -or
                        $value -match '\.[a-zA-Z0-9]{1,6}$') {
                        & $registerCandidate $value
                    }
                    break
                }
                ([System.Management.Automation.PSTokenType]::CommandArgument) {
                    if ($waitForValue) {
                        $waitForValue = $false
                        break
                    }
                    $value = Convert-PathToken -Value $token.Content
                    if (Test-StringEmpty -Value $value) {
                        break
                    }
                    if ($value -match '[\\/:]' -or
                        $value.StartsWith('.') -or
                        $value -match '\.[a-zA-Z0-9]{1,6}$') {
                        & $registerCandidate $value
                    }
                    break
                }
                default {
                    if ($token.Type -ne [System.Management.Automation.PSTokenType]::NewLine -and
                        $token.Type -ne [System.Management.Automation.PSTokenType]::Comment) {
                        $waitForValue = $false
                    }
                }
            }
        }
    }
    catch {
        Write-Host '[备份] 命令解析失败，已跳过路径提取：{0}' -f $_.Exception.Message -ForegroundColor DarkYellow
    }

    return $candidates
}

function Resolve-ExistingPath {
    param (
        [string]$Candidate
    )

    $normalized = Convert-PathToken -Value $Candidate
    if (Test-StringEmpty -Value $normalized) {
        return @()
    }

    $expanded = Convert-PathToken -Value (Expand-CommandPathVariables -Candidate $normalized)

    $results = New-Object System.Collections.Generic.List[string]
    $seenResults = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $addResult = {
        param($path)
        if (Test-StringEmpty -Value $path) {
            return
        }
        if ($seenResults.Add($path)) {
            $null = $results.Add($path)
        }
    }

    $variants = New-Object System.Collections.Generic.List[string]
    $null = $variants.Add($normalized)
    if (-not (Test-StringEmpty -Value $expanded) -and
        -not $expanded.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $variants.Add($expanded)
    }

    foreach ($candidatePath in $variants) {
        $resolvedByResolvers = $false
        $resolvers = @(
            { Resolve-Path -LiteralPath $args[0] -ErrorAction Stop },
            { Resolve-Path -Path $args[0] -ErrorAction Stop }
        )

        foreach ($resolver in $resolvers) {
            try {
                $resolverResults = & $resolver $candidatePath
                foreach ($match in $resolverResults) {
                    $resolvedByResolvers = $true
                    & $addResult $match.ProviderPath
                }
                if ($resolvedByResolvers) {
                    break
                }
            }
            catch {
                continue
            }
        }

        if ($resolvedByResolvers) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $candidatePath -ErrorAction Stop) {
                $converted = $null
                try {
                    $converted = Convert-Path -LiteralPath $candidatePath -ErrorAction Stop
                }
                catch {
                    $converted = $candidatePath
                }
                & $addResult $converted
            }
        }
        catch {
            continue
        }
    }

    return ,$results.ToArray()
}

function Get-CommandFileTargets {
    <#
        .SYNOPSIS
            汇总命令中可备份的路径，并区分可解析与不可解析的条目。
    #>
    param (
        [string]$CommandText
    )

    $result = [PSCustomObject]@{
        Resolved   = New-Object System.Collections.Generic.List[string]
        Unresolved = New-Object System.Collections.Generic.List[string]
    }

    if (Test-StringEmpty -Value $CommandText) {
        return $result
    }

    $resolvedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $unresolvedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $candidates = Get-CommandPathCandidates -CommandText $CommandText
    foreach ($candidate in $candidates) {
        $normalized = Convert-PathToken -Value $candidate
        if (Test-StringEmpty -Value $normalized) {
            continue
        }

        $resolvedMatches = @()
        try {
            $resolvedMatches = @(Resolve-ExistingPath -Candidate $normalized)
        }
        catch {
            $resolvedMatches = @()
        }

        if ($resolvedMatches.Count -gt 0) {
            foreach ($match in $resolvedMatches) {
                if ($resolvedSet.Add($match)) {
                    $null = $result.Resolved.Add($match)
                }
            }
        }
        elseif ($unresolvedSet.Add($normalized)) {
            $null = $result.Unresolved.Add($normalized)
        }
    }

    return $result
}

function New-PathBackupArchive {
    <#
        .SYNOPSIS
            在源文件或目录同级创建压缩备份。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        Write-Host "[备份] 未找到路径：$LiteralPath" -ForegroundColor Yellow
        return $null
    }

    try {
        $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    }
    catch {
        Write-Host "[备份] 获取路径信息失败：$($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $targetName = if ($item.PSIsContainer) { $item.Name } else { $item.BaseName }
    $targetDirectory = if ($item.PSIsContainer) {
        Split-Path -Path $item.FullName -Parent
    }
    else {
        $item.DirectoryName
    }
    if (Test-StringEmpty -Value $targetDirectory) {
        $targetDirectory = Split-Path -Path $item.FullName -Parent
    }

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $zipName = "{0}_backup_{1}.zip" -f $targetName, $timestamp
    $zipPath = Join-Path -Path $targetDirectory -ChildPath $zipName

    $suffix = 1
    while (Test-Path -LiteralPath $zipPath) {
        $zipName = "{0}_backup_{1}_{2}.zip" -f $targetName, $timestamp, $suffix
        $zipPath = Join-Path -Path $targetDirectory -ChildPath $zipName
        $suffix++
    }

    try {
        Compress-Archive -LiteralPath $item.FullName -DestinationPath $zipPath -Force
        $typeText = if ($item.PSIsContainer) { '目录' } else { '文件' }
        $message = "[备份] 已为{0}创建压缩包：{1}" -f $typeText, $zipPath
        Write-Host $message -ForegroundColor Cyan
        return [PSCustomObject]@{
            TargetFile = $item.FullName
            TargetType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
            BackupFile = $zipPath
            Timestamp  = Get-Date
        }
    }
    catch {
        Write-Host "[备份] 创建压缩包失败：$($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Read-YesNoChoice {
    param (
        [string]$Message,
        [ValidateSet('Y', 'N')]
        [string]$Default = $null
    )

    while ($true) {
        $prompt = $Message
        if ($Default) {
            $prompt = "$prompt (默认$Default)"
        }

        $choice = Read-Host $prompt
        if (Test-StringEmpty -Value $choice) {
            if ($Default) {
                return $Default -eq 'Y'
            }
            continue
        }

        $normalized = $choice.ToUpper()
        if ($normalized -in @('Y', 'N')) {
            return $normalized -eq 'Y'
        }
    }
}

function Invoke-BackupSelection {
    <#
        .SYNOPSIS
            在执行命令前询问是否需要备份相关路径。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )

    $result = [PSCustomObject]@{
        Backups     = @()
        ShouldAbort = $false
    }

    if (-not (Test-CommandRequiresBackupPrompt -CommandText $CommandText)) {
        return $result
    }

    try {
        $targetInfo = Get-CommandFileTargets -CommandText $CommandText
    }
    catch {
        Write-Host "[备份] 路径解析失败，已跳过本次备份提示：$($_.Exception.Message)" -ForegroundColor Yellow
        return $result
    }

    if (-not $targetInfo) {
        return $result
    }

    $targets = if ($targetInfo.Resolved) { $targetInfo.Resolved } else { @() }
    $unresolved = if ($targetInfo.Unresolved) { $targetInfo.Unresolved } else { @() }

    if ($unresolved.Count -gt 0) {
        Write-Host "[提示] 以下路径无法自动解析以执行备份，请确认是否需要先手动处理：" -ForegroundColor Yellow
        foreach ($pattern in $unresolved) {
            Write-Host " - $pattern" -ForegroundColor DarkYellow
        }

        if (-not (Read-YesNoChoice -Message '是否立即继续执行命令？(Y=继续执行, N=取消执行命令)')) {
            $result.ShouldAbort = $true
            return $result
        }
    }

    if ($targets.Count -eq 0) {
        return $result
    }

    foreach ($target in $targets) {
        $pathTypeLabel = '路径'
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $pathTypeLabel = '文件'
        }
        elseif (Test-Path -LiteralPath $target -PathType Container) {
            $pathTypeLabel = '目录'
        }

        if (Read-YesNoChoice -Message "检测到$pathTypeLabel '$target'，是否先生成备份？(Y/N)") {
            $backup = New-PathBackupArchive -LiteralPath $target
            if ($backup) {
                $result.Backups += $backup
            }
        }
        else {
            Write-Host "[备份] 已放弃为 $target 创建备份。" -ForegroundColor DarkYellow
        }
    }

    return $result
}

