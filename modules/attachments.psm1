# modules/attachments.ps1

<#
    提供本地附件上传组件：支持将用户指定的文件/图片转为 Base64，
    在下一次 AI 请求时自动插入到消息列表中。
#>

if (-not (Get-Variable -Name PendingAttachments -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PendingAttachments = New-Object System.Collections.ArrayList
}

$script:MaxAttachmentSizeBytes = 2MB

function Initialize-AIAttachmentStore {
    if (-not (Get-Variable -Name PendingAttachments -Scope Script -ErrorAction SilentlyContinue)) {
        $script:PendingAttachments = New-Object System.Collections.ArrayList
    }
}

function Get-AttachmentMimeType {
    param (
        [string]$Path
    )

    $ext = [System.IO.Path]::GetExtension($Path)
    switch ($ext.ToLowerInvariant()) {
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif' { return 'image/gif' }
        '.bmp' { return 'image/bmp' }
        '.webp' { return 'image/webp' }
        '.svg' { return 'image/svg+xml' }
        '.pdf' { return 'application/pdf' }
        '.txt' { return 'text/plain' }
        '.json' { return 'application/json' }
        '.csv' { return 'text/csv' }
        default { return 'application/octet-stream' }
    }
}

function Test-AttachmentIsImage {
    param (
        [string]$Path
    )

    $imageExt = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg')
    $ext = [System.IO.Path]::GetExtension($Path)
    return $imageExt -contains $ext.ToLowerInvariant()
}

function Read-AttachmentBytes {
    param (
        [System.IO.FileInfo]$FileInfo
    )

    try {
        return [System.IO.File]::ReadAllBytes($FileInfo.FullName)
    }
    catch {
        Write-Host "[附件] 读取文件失败：$($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Add-AIAttachment {
    <#
        .SYNOPSIS
            将本地文件/图片读入队列，待下次 AI 请求时自动附加。
    #>
    param (
        [string[]]$Paths,
        [string]$Note = ""
    )

    Initialize-AIAttachmentStore

    if (-not $Paths -or $Paths.Count -eq 0) {
        $userInput = Read-Host "请输入要上传的文件路径（多个用分号或逗号分隔，留空取消）"
        if (Test-StringEmpty -Value $userInput) {
            Write-Host "[附件] 未提供任何路径，已取消。" -ForegroundColor DarkYellow
            return
        }
        $Paths = $userInput -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { -not (Test-StringEmpty -Value $_) }
    }

    $maxSize = $script:MaxAttachmentSizeBytes
    $queued = 0

    foreach ($path in $Paths) {
        if (Test-StringEmpty -Value $path) {
            continue
        }

        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
        }
        catch {
            Write-Host "[附件] 找不到文件：$path" -ForegroundColor Yellow
            continue
        }

        if ($item.PSIsContainer) {
            Write-Host "[附件] 跳过目录，只支持单文件上传：$($item.FullName)" -ForegroundColor DarkYellow
            continue
        }

        if ($item.Length -gt $maxSize) {
            $sizeMB = [Math]::Round($item.Length / 1MB, 2)
            $limitMB = [Math]::Round($maxSize / 1MB, 2)
            Write-Host "[附件] 文件过大（$sizeMB MB），超过上限 $limitMB MB：$($item.Name)" -ForegroundColor Yellow
            continue
        }

        $bytes = Read-AttachmentBytes -FileInfo $item
        if (-not $bytes) {
            continue
        }

        $base64 = [Convert]::ToBase64String($bytes)
        $mime = Get-AttachmentMimeType -Path $item.FullName
        $isImage = Test-AttachmentIsImage -Path $item.FullName
        $kind = if ($isImage) { 'Image' } else { 'File' }

        $attachment = [PSCustomObject]@{
            FullPath  = $item.FullName
            FileName  = $item.Name
            Size      = $item.Length
            MimeType  = $mime
            Base64    = $base64
            Kind      = $kind
            Note      = $Note
        }

        $null = $script:PendingAttachments.Add($attachment)
        $queued++
        Write-Host "[附件] 已加入待发送队列：$($item.Name)（$mime，$($item.Length) 字节）" -ForegroundColor Cyan
    }

    if ($queued -eq 0) {
        Write-Host "[附件] 本次未成功加入任何附件。" -ForegroundColor DarkYellow
    }
    else {
        Write-Host "[附件] 当前队列共 $($script:PendingAttachments.Count) 个附件，将随下一次 AI 请求发送。" -ForegroundColor Green
    }
}

function Get-PendingAIAttachments {
    Initialize-AIAttachmentStore
    return @($script:PendingAttachments)
}

function Clear-PendingAIAttachments {
    Initialize-AIAttachmentStore
    $count = $script:PendingAttachments.Count
    $script:PendingAttachments.Clear()
    Write-Host "[附件] 已清空队列（清理 $count 个）。" -ForegroundColor DarkYellow
}

function Pop-AIAttachmentMessages {
    <#
        .SYNOPSIS
            将队列中的附件转换为 Chat Completions 消息，并清空队列。
    #>

    Initialize-AIAttachmentStore

    if ($script:PendingAttachments.Count -eq 0) {
        return @()
    }

    $pending = @($script:PendingAttachments)
    $script:PendingAttachments.Clear()

    $contentParts = New-Object System.Collections.ArrayList
    foreach ($item in $pending) {
        if (-not $item) { continue }

        if ($item.Kind -eq 'Image') {
            $dataUrl = "data:$($item.MimeType);base64,$($item.Base64)"
            $contentParts.Add(@{
                    type      = 'image_url'
                    image_url = @{
                        url    = $dataUrl
                        detail = 'high'
                    }
                }) | Out-Null
            continue
        }

        $text = "本地文件：$($item.FileName)（$($item.MimeType)，$($item.Size) 字节）"
        if (-not (Test-StringEmpty -Value $item.Note)) {
            $text = "备注：$($item.Note)`n$text"
        }
        $text = "$text`nBase64：$($item.Base64)"

        $contentParts.Add(@{
                type = 'text'
                text = $text
            }) | Out-Null
    }

    if ($contentParts.Count -eq 0) {
        return @()
    }

    $message = @{ role = 'user'; content = $contentParts }
    return ,@($message)
}

Export-ModuleMember -Function * -Alias * -Variable *
