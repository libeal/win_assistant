<#
    modules/backup.ps1
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
        'new-pathbackuparchive',
        'new-filebackuparchive',
        'expand-archive'
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

function Test-PathPatternIndicator {
    param (
        [string]$Candidate
    )

    if (Test-StringEmpty -Value $Candidate) {
        return $false
    }

    if ($Candidate -match '[*?]') {
        return $true
    }

    if ($Candidate -match '\$env:') {
        return $true
    }

    if ($Candidate -match '\$\(') {
        return $true
    }

    return $false
}

function Test-LiteralPathIndicator {
    param (
        [string]$Candidate
    )

    if (Test-StringEmpty -Value $Candidate) {
        return $false
    }

    $value = $Candidate.Trim('"', "'")
    if (Test-StringEmpty -Value $value) {
        return $false
    }

    if ($value -match '^[a-zA-Z]:\\') {
        return $true
    }

    if ($value.StartsWith('\\')) {
        return $true
    }

    if ($value.StartsWith('.')) {
        return $true
    }

    if ($value.IndexOf('\') -ge 0 -or $value.IndexOf('/') -ge 0) {
        return $true
    }

    return $false
}

function Get-CommandFileTargets {
    <#
        .SYNOPSIS
            从命令字符串中提取可能的路径（文件或目录）。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )

    $resolvedTargets = New-Object System.Collections.ArrayList
    $unresolvedPatterns = New-Object System.Collections.ArrayList

    if (Test-StringEmpty -Value $CommandText) {
        return [PSCustomObject]@{
            Resolved   = $resolvedTargets
            Unresolved = $unresolvedPatterns
        }
    }

    $addCandidate = {
        param($candidate)
        if (Test-StringEmpty -Value $candidate) {
            return
        }
        $resolvedItems = Resolve-ExistingPath -Candidate $candidate
        $added = $false
        foreach ($resolved in @($resolvedItems)) {
            if ($resolved -and -not $resolvedTargets.Contains($resolved)) {
                [void]$resolvedTargets.Add($resolved)
                $added = $true
            }
        }

        $shouldTrackUnresolved = $false
        if (Test-PathPatternIndicator -Candidate $candidate) {
            $shouldTrackUnresolved = $true
        }
        elseif (Test-LiteralPathIndicator -Candidate $candidate) {
            $shouldTrackUnresolved = $true
        }

        if (-not $added -and $shouldTrackUnresolved) {
            if (-not $unresolvedPatterns.Contains($candidate)) {
                [void]$unresolvedPatterns.Add($candidate)
            }
        }
    }

    $quotedMatches = [regex]::Matches($CommandText, "([\""'])(.+?)\1")
    foreach ($match in $quotedMatches) {
        $value = $match.Groups[2].Value.Trim()
        & $addCandidate $value
    }

    $bareMatches = [regex]::Matches($CommandText, "(?<![\w])([a-zA-Z]:\\[^\s\""']+)")
    foreach ($match in $bareMatches) {
        $value = $match.Groups[1].Value.TrimEnd(';', ',', ')')
        & $addCandidate $value
    }

    $uncMatches = [regex]::Matches($CommandText, "(?<![\w])(\\\\\\\\[^\s\""']+)")
    foreach ($match in $uncMatches) {
        $value = $match.Groups[1].Value.TrimEnd(';', ',', ')')
        & $addCandidate $value
    }

    try {
        $errors = $null
        $tokens = [System.Management.Automation.PSParser]::Tokenize($CommandText, [ref]$errors)
        $skipValueParameters = @('-filter', '-include', '-exclude', '-filefilter', '-name')
        $pendingSkipParameter = $null

        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $token = $tokens[$i]

            if ($pendingSkipParameter -and
                $token.Type -ne [System.Management.Automation.PSTokenType]::NewLine -and
                $token.Type -ne [System.Management.Automation.PSTokenType]::Comment) {
                $pendingSkipParameter = $null
                if ($token.Type -ne [System.Management.Automation.PSTokenType]::CommandParameter) {
                    continue
                }
            }

            if ($token.Type -eq [System.Management.Automation.PSTokenType]::CommandParameter) {
                $parameterName = $token.Content.ToLowerInvariant()
                if ($skipValueParameters -contains $parameterName) {
                    $pendingSkipParameter = $parameterName
                }
                else {
                    $pendingSkipParameter = $null
                }
                continue
            }

            if ($token.Type -ne [System.Management.Automation.PSTokenType]::String -and
                $token.Type -ne [System.Management.Automation.PSTokenType]::CommandArgument) {
                continue
            }

            if ($pendingSkipParameter) {
                $pendingSkipParameter = $null
                continue
            }

            $value = $token.Content.Trim('"', "'").Trim()
            if (Test-StringEmpty -Value $value) {
                continue
            }

            $looksLikePath = $false
            if ($value.IndexOf('\') -ge 0 -or $value.IndexOf('/') -ge 0) {
                $looksLikePath = $true
            }
            elseif ($value.StartsWith('.')) {
                $looksLikePath = $true
            }
            elseif ($value -match "\.[a-zA-Z0-9]{1,6}$") {
                $looksLikePath = $true
            }

            if ($looksLikePath) {
                & $addCandidate $value
            }
        }
    }
    catch {
        Write-Host "[备份] 命令解析失败，已回退到基础路径匹配：$($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return [PSCustomObject]@{
        Resolved   = $resolvedTargets
        Unresolved = $unresolvedPatterns
    }
}

function Resolve-ExistingPath {
    param (
        [string]$Candidate
    )

    if (Test-StringEmpty -Value $Candidate) {
        return @()
    }

    $normalized = $Candidate.Trim('"', "'")
    $expanded = Expand-CommandPathVariables -Candidate $normalized

    $pathsToTry = New-Object System.Collections.Generic.List[string]
    if (-not (Test-StringEmpty -Value $normalized)) {
        $pathsToTry.Add($normalized) | Out-Null
    }
    if (-not (Test-StringEmpty -Value $expanded) -and $expanded -ne $normalized) {
        $pathsToTry.Add($expanded) | Out-Null
    }

    $results = New-Object System.Collections.Generic.List[string]

    foreach ($candidatePath in $pathsToTry) {
        try {
            $literalMatches = Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop
            foreach ($match in $literalMatches) {
                $path = $match.ProviderPath
                if ($path -and -not $results.Contains($path)) {
                    $results.Add($path) | Out-Null
                }
            }
            continue
        }
        catch {
            # ignore literal failures
        }

        try {
            $wildcardMatches = Resolve-Path -Path $candidatePath -ErrorAction Stop
            foreach ($match in $wildcardMatches) {
                $path = $match.ProviderPath
                if ($path -and -not $results.Contains($path)) {
                    $results.Add($path) | Out-Null
                }
            }
        }
        catch {
            try {
                if (Test-Path -Path $candidatePath -ErrorAction Stop) {
                    try {
                        $converted = Convert-Path -Path $candidatePath -ErrorAction Stop
                        if ($converted -and -not $results.Contains($converted)) {
                            $results.Add($converted) | Out-Null
                        }
                    }
                    catch {
                        # ignore convert failures
                    }
                }
            }
            catch {
                # 静默忽略 Test-Path 的权限或访问异常
            }
        }
    }

    return ,$results.ToArray()
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

    $isDirectory = $item.PSIsContainer
    if ($isDirectory) {
        $targetName = $item.Name
    }
    else {
        $targetName = $item.BaseName
    }
    if ($isDirectory) {
        $targetDirectory = Split-Path -Path $item.FullName -Parent
    }
    else {
        $targetDirectory = $item.DirectoryName
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
        if ($isDirectory) {
            $typeText = "目录"
        }
        else {
            $typeText = "文件"
        }
        $message = "[备份] 已为{0}创建压缩包：{1}" -f $typeText, $zipPath
        Write-Host $message -ForegroundColor Cyan
        return [PSCustomObject]@{
            TargetFile = $item.FullName
            TargetType = if ($isDirectory) { 'Directory' } else { 'File' }
            BackupFile = $zipPath
            Timestamp  = Get-Date
        }
    }
    catch {
        Write-Host "[备份] 创建压缩包失败：$($_.Exception.Message)" -ForegroundColor Red
        return $null
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

    $targetInfo = Get-CommandFileTargets -CommandText $CommandText
    $targets = $targetInfo.Resolved
    $unresolved = $targetInfo.Unresolved

    if ($unresolved.Count -gt 0) {
        Write-Host "[提示] 以下路径无法自动解析以执行备份，请确认是否需要先手动处理：" -ForegroundColor Yellow
        foreach ($pattern in $unresolved) {
            Write-Host " - $pattern" -ForegroundColor DarkYellow
        }
        $manualChoice = ""
        while ($manualChoice -notin @('Y', 'N')) {
            $manualChoice = Read-Host "是否立即继续执行命令？(Y=继续执行, N=取消执行命令)"
            $manualChoice = $manualChoice.ToUpper()
        }
        if ($manualChoice -eq 'N') {
            $result.ShouldAbort = $true
            return $result
        }
    }

    if ($targets.Count -eq 0) {
        return $result
    }

    foreach ($target in $targets) {
        $pathTypeLabel = "路径"
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $pathTypeLabel = "文件"
        }
        elseif (Test-Path -LiteralPath $target -PathType Container) {
            $pathTypeLabel = "目录"
        }

        $choice = ""
        while ($choice -notin @('Y', 'N')) {
            $choice = Read-Host "检测到$pathTypeLabel '$target'，是否先生成备份？(Y/N)"
            $choice = $choice.ToUpper()
        }

        if ($choice -eq 'Y') {
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
