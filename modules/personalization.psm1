# modules/personalization.ps1

<#
    提供个性化配置文件的初始化与读取能力，作为提示词补充信息存在，不参与上下文记忆。
#>

$script:PersonalizationProfilePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "personalization.md"

function Initialize-PersonalizationProfile {
    <#
        .SYNOPSIS
            确保个性化配置文件存在，供用户按需填写。
    #>
    if (Test-Path -LiteralPath $script:PersonalizationProfilePath) {
        return
    }

    $template = @"
# 个性化配置

请在此记录有助于 AI 理解本机环境或习惯的长期信息，避免写入敏感数据。
- 示例：常用开发目录、代理配置、运行限制、偏好工具等
- 当无需记录时可保持为空
"@

    try {
        Set-Content -LiteralPath $script:PersonalizationProfilePath -Value $template -Encoding UTF8 -Force
    }
    catch {
        Write-Host "[提示] 无法创建个性化配置文件：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-PersonalizationProfileContent {
    <#
        .SYNOPSIS
            读取个性化配置文件原文，供提示词注入。
    #>
    if (-not (Test-Path -LiteralPath $script:PersonalizationProfilePath)) {
        return ""
    }

    try {
        return Get-Content -LiteralPath $script:PersonalizationProfilePath -Raw -Encoding UTF8
    }
    catch {
        Write-Host "[提示] 读取个性化配置失败：$($_.Exception.Message)" -ForegroundColor Yellow
        return ""
    }
}

Initialize-PersonalizationProfile

Export-ModuleMember -Function * -Alias * -Variable *
