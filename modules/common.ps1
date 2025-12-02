# modules/common.ps1

<#
    提供在多个模块间复用的通用工具函数，目前用于安全读取 AI 响应字段。
#>

if (-not (Test-Path variable:script:WindowsAIProviderWarningIssued)) {
    $script:WindowsAIProviderWarningIssued = $false
}

function Get-AIResponseValue {
    <#
        .SYNOPSIS
            从 AI 响应中安全读取指定字段，可配置空白字符串视为默认值。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object]$AIResponse,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [object]$Default = $null,

        [switch]$TreatEmptyStringAsNull
    )

    if (-not $AIResponse) {
        return $Default
    }

    $property = $AIResponse.PSObject.Properties[$PropertyName]
    if (-not $property) {
        return $Default
    }

    $value = $property.Value

    if ($TreatEmptyStringAsNull -and $value -is [string] -and (Test-StringEmpty -Value $value)) {
        return $Default
    }

    return $value
}

function Get-AIResponseCommands {
    <#
        .SYNOPSIS
            将 AI 响应中的 commands 字段转换为可安全枚举的数组。
    #>
    param (
        [object]$AIResponse
    )

    $commands = Get-AIResponseValue -AIResponse $AIResponse -PropertyName 'commands'
    if (-not $commands) {
        return @()
    }

    if ($commands -is [System.Collections.IEnumerable] -and -not ($commands -is [string])) {
        return @($commands)
    }

    return @($commands)
}

function Format-HttpError {
    <#
        .SYNOPSIS
            从异常中提取 HTTP 状态码与返回体，避免各处重复读取响应流。
    #>
    param (
        [System.Exception]$Exception
    )

    $result = [PSCustomObject]@{
        StatusCode = $null
        Body       = $null
    }

    if (-not $Exception) {
        return $result
    }

    $response = $null
    foreach ($candidate in @($Exception, $Exception.InnerException)) {
        if ($candidate -and $candidate.PSObject.Properties['Response'] -and $candidate.Response) {
            $response = $candidate.Response
            break
        }
    }

    if (-not $response) {
        return $result
    }

    try {
        if ($response.StatusCode -and $response.StatusCode.PSObject.Properties['value__']) {
            $result.StatusCode = $response.StatusCode.value__
        }
        elseif ($response.StatusCode) {
            $result.StatusCode = $response.StatusCode
        }
    }
    catch {
        $result.StatusCode = $null
    }

    try {
        $stream = $response.GetResponseStream()
        if ($stream) {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            $result.Body = $reader.ReadToEnd()
            $reader.Close()
        }
    }
    catch {
        $result.Body = $null
    }

    return $result
}

function Get-MissingConfigFields {
    <#
        .SYNOPSIS
            检查配置对象中是否缺少指定字段，返回所有缺失字段。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredFields
    )

    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($field in $RequiredFields) {
        if (Test-StringEmpty -Value $field) {
            continue
        }

        if (-not ($Config.ContainsKey($field))) {
            $missing.Add($field) | Out-Null
            continue
        }

        $value = $Config[$field]
        if ($null -eq $value) {
            $missing.Add($field) | Out-Null
            continue
        }

        if ($value -is [string] -and (Test-StringEmpty -Value $value)) {
            $missing.Add($field) | Out-Null
        }
    }

    return ,$missing.ToArray()
}

function Test-StringEmpty {
    <#
        .SYNOPSIS
            判断字符串是否为 null、空或仅包含空白。
    #>
    param (
        [string]$Value
    )

    return [string]::IsNullOrWhiteSpace($Value)
}

function ConvertTo-Hashtable {
    <#
        .SYNOPSIS
            将 ConvertFrom-Json 得到的对象递归转换为 Hashtable。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += ConvertTo-Hashtable -InputObject $item
        }
        return $list
    }

    if ($InputObject -is [pscustomobject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable -InputObject $prop.Value
        }
        return $hash
    }

    return $InputObject
}

function Import-WindowsAIConfig {
    <#
        .SYNOPSIS
            统一读取并校验 config.json，自动补默认值并避免重复警告。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [string[]]$RequiredFields = @('aiProvider', 'apiKey', 'apiUrl', 'model'),

        [int]$DefaultMaxContextTurns = 3
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw [System.IO.FileNotFoundException]::new("未在当前目录找到 config.json：$ConfigPath")
    }

    try {
        $configContent = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        $configObject = $configContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("读取或解析 config.json 失败，请检查 JSON 格式。", $_.Exception)
    }

    $config = ConvertTo-Hashtable -InputObject $configObject

    $missingFields = Get-MissingConfigFields -Config $config -RequiredFields $RequiredFields
    if ($missingFields.Count -gt 0) {
        $missingList = $missingFields -join ', '
        throw [System.Exception]::new("配置项缺失或为空：$missingList，请在 config.json 中补齐后重试。")
    }

    $maxContextTurns = $DefaultMaxContextTurns
    if ($config.ContainsKey('maxContextTurns') -and $null -ne $config.maxContextTurns) {
        try {
            $maxContextTurns = [int]$config.maxContextTurns
        }
        catch {
            $maxContextTurns = $DefaultMaxContextTurns
        }
    }
    else {
        $config.maxContextTurns = $DefaultMaxContextTurns
    }

    $maxContextTurns = [Math]::Max(0, $maxContextTurns)
    $config.maxContextTurns = $maxContextTurns

    if (-not [string]::IsNullOrWhiteSpace($config.aiProvider) -and
        -not $config.aiProvider.Equals('OpenAI', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not $script:WindowsAIProviderWarningIssued) {
            Write-Host "[提示] 当前仅测试过 OpenAI，检测到 aiProvider = '$($config.aiProvider)'。" -ForegroundColor Yellow
            $script:WindowsAIProviderWarningIssued = $true
        }
    }

    return $config
}
