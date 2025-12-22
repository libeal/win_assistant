# modules/mcp.ps1

$script:McpRegistry = @{}
$script:McpDefaultService = $null
$script:McpConfigPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "mcp.config.json"
$script:McpPromptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "mcp.md"

function New-McpResult {
    <#
        .SYNOPSIS
            统一的 MCP 结果对象，便于上层消费与日志化。
    #>
    param (
        [bool]$Success,
        [string]$Service,
        [string]$Transport,
        [object]$Data = $null,
        [string]$ErrorMessage = $null,
        [string]$ErrorCode = $null
    )

    return [PSCustomObject]@{
        success   = $Success
        error     = $ErrorMessage
        errorCode = $ErrorCode
        service   = $Service
        transport = $Transport
        data      = $Data
        timestamp = Get-Date
    }
}

function New-McpErrorResult {
    param (
        [string]$Service,
        [string]$Transport,
        [string]$ErrorMessage,
        [string]$ErrorCode = 'ERR_MCP_GENERIC'
    )

    return New-McpResult -Success:$false -Service $Service -Transport $Transport -Data $null -ErrorMessage $ErrorMessage -ErrorCode $ErrorCode
}

function ConvertFrom-McpErrorObjectToMessage {
    <#
        .SYNOPSIS
            将 JSON-RPC error 对象统一转为可读字符串。
    #>
    param (
        [object]$ErrorObject
    )

    if (-not $ErrorObject) {
        return ""
    }

    if ($ErrorObject -is [string]) {
        return $ErrorObject
    }

    try {
        if ($ErrorObject.PSObject.Properties['message'] -and -not [string]::IsNullOrWhiteSpace([string]$ErrorObject.message)) {
            return [string]$ErrorObject.message
        }
    }
    catch {
    }

    try {
        return ($ErrorObject | ConvertTo-Json -Depth 6 -Compress)
    }
    catch {
        try { return $ErrorObject.ToString() } catch { return "" }
    }
}

function Write-McpTrace {
    <#
        .SYNOPSIS
            将 MCP 调用的关键信息追加到日志文件，便于排查。
    #>
    param (
        [string]$Service,
        [string]$Transport,
        [string]$Stage,
        [string]$Message,
        [object]$Metadata = $null
    )

    try {
        $logRoot = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "logs"
        if (-not (Test-Path -LiteralPath $logRoot)) {
            New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        }
        $logFile = Join-Path -Path $logRoot -ChildPath "mcp-trace.log"
        $entry = [PSCustomObject]@{
            timestamp = Get-Date
            service   = $Service
            transport = $Transport
            stage     = $Stage
            message   = $Message
            metadata  = $Metadata
        }
        $json = $entry | ConvertTo-Json -Depth 6 -Compress
        if ($json.Length -gt 4000) {
            $json = $json.Substring(0, 4000)
        }
        Add-Content -LiteralPath $logFile -Value $json -Encoding UTF8
    }
    catch {
        # 日志失败不影响主流程
    }
}

function Initialize-McpPrompt {
    <#
        .SYNOPSIS
            确保 MCP 提示文件存在，供提示词注入使用。
    #>
    if (Test-Path -LiteralPath $script:McpPromptPath) {
        return
    }

    $template = @"
# MCP 调用提示

请在此文件告知 AI 如何使用 MCP 服务，例如可用方法、示例命令与注意事项。
避免写入敏感数据，可根据实际服务调整内容。
"@

    try {
        Set-Content -LiteralPath $script:McpPromptPath -Value $template -Encoding UTF8 -Force
    }
    catch {
        Write-Host "[MCP] 无法创建 MCP 提示文件：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-McpPromptContent {
    <#
        .SYNOPSIS
            读取 MCP 提示文件内容，供提示词注入。
    #>
    if (-not (Test-Path -LiteralPath $script:McpPromptPath)) {
        return ""
    }

    try {
        return Get-Content -LiteralPath $script:McpPromptPath -Raw -Encoding UTF8
    }
    catch {
        Write-Host "[MCP] 读取 MCP 提示文件失败：$($_.Exception.Message)" -ForegroundColor Yellow
        return ""
    }
}

function Import-McpConfig {
    <#
        .SYNOPSIS
            读取独立的 MCP 配置文件。
    #>
    param (
        [string]$ConfigPath = $script:McpConfigPath
    )

    $configObject = $null

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
            $configObject = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Host "[MCP] 读取独立配置失败：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not $configObject) {
        return $null
    }

    try {
        $hash = ConvertTo-Hashtable -InputObject $configObject
        # 归一化 services 字段，避免单元素被解析成 hashtable 造成后续遍历异常
        if ($hash -and $hash.ContainsKey('services') -and $hash.services) {
            if ($hash.services -is [hashtable]) {
                $hash.services = @($hash.services)
            }
            elseif (-not ($hash.services -is [System.Collections.IEnumerable] -and -not ($hash.services -is [string]))) {
                $hash.services = @()
            }
        }
        return $hash
    }
    catch {
        return $null
    }
}

function Initialize-McpRegistry {
    <#
        .SYNOPSIS
            根据 MCP 配置初始化服务注册表。
    #>
    param (
        [hashtable]$McpConfig
    )

    $script:McpRegistry = @{}
    $script:McpDefaultService = $null

    if (-not $McpConfig) {
        return
    }

    $mcp = $McpConfig

    if ($mcp.ContainsKey('enabled') -and -not $mcp.enabled) {
        return
    }

    $services = @()
    if ($mcp.ContainsKey('services') -and $mcp.services) {
        $rawServices = $mcp.services
        if ($rawServices -is [System.Collections.IDictionary] -or $rawServices -is [pscustomobject]) {
            # 单个服务定义（已被 ConvertTo-Hashtable 处理成 hashtable 时），避免枚举键名
            $services = @($rawServices)
        }
        elseif ($rawServices -is [System.Collections.IEnumerable] -and -not ($rawServices -is [string])) {
            $services = @($rawServices)
        }
    }

    if ($services.Count -eq 0) {
        return
    }

    $registry = @{}

    foreach ($service in $services) {
        if (-not $service) { continue }

        $serviceTable = $service
        if ($serviceTable -isnot [hashtable]) {
            try { $serviceTable = ConvertTo-Hashtable -InputObject $service } catch { $serviceTable = $null }
        }
        if (-not $serviceTable) { continue }

        $name = $null
        if ($serviceTable.ContainsKey('name')) { $name = $serviceTable['name'] }
        if ($name) { $name = [string]$name }

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host "[MCP] 跳过未命名的服务配置。" -ForegroundColor Yellow
            continue
        }

        if ($registry.ContainsKey($name)) {
            Write-Host "[MCP] 服务名称重复，已跳过：$name" -ForegroundColor Yellow
            continue
        }

        $transport = $null
        if ($serviceTable.ContainsKey('transport')) { $transport = $serviceTable['transport'] }
        if (-not $transport) {
            Write-Host "[MCP] 服务缺少 transport 配置，已跳过：$name" -ForegroundColor Yellow
            continue
        }

        if ($transport -isnot [hashtable]) {
            try { $transport = ConvertTo-Hashtable -InputObject $transport } catch { $transport = $null }
        }
        if (-not $transport) {
            Write-Host "[MCP] 服务缺少 transport 配置，已跳过：$name" -ForegroundColor Yellow
            continue
        }

        $type = $null
        if ($transport.ContainsKey('type')) { $type = $transport['type'] }
        if ($type) { $type = [string]$type }

        # 容错：若未能读取到 type，则默认按 SSE 处理，避免合法配置被忽略
        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = 'sse'
        }

        $normalizedType = $type.ToLowerInvariant()
        if ($normalizedType -ne 'sse' -and $normalizedType -ne 'websocket' -and $normalizedType -ne 'stdio' -and $normalizedType -ne 'streamablehttp') {
            Write-Host "[MCP] 服务 $name 的传输类型不受支持：$type" -ForegroundColor Yellow
            continue
        }

        $timeout = 60
        $idleTimeout = $null
        $totalTimeout = $null
        $retry = 1
        $timeoutSec = $null
        if ($serviceTable.ContainsKey('timeoutSec')) { $timeoutSec = $serviceTable['timeoutSec'] }
        if ($timeoutSec) {
            try {
                $timeout = [Math]::Max(10, [int]$timeoutSec)
            }
            catch {
                $timeout = 60
            }
        }

        $idleTimeoutSec = $null
        if ($serviceTable.ContainsKey('idleTimeoutSec')) { $idleTimeoutSec = $serviceTable['idleTimeoutSec'] }
        if ($idleTimeoutSec) {
            try {
                $idleTimeout = [Math]::Max(5, [int]$idleTimeoutSec)
            }
            catch {
                $idleTimeout = $null
            }
        }

        $totalTimeoutSec = $null
        if ($serviceTable.ContainsKey('totalTimeoutSec')) { $totalTimeoutSec = $serviceTable['totalTimeoutSec'] }
        if ($totalTimeoutSec) {
            try {
                $totalTimeout = [Math]::Max($timeout, [int]$totalTimeoutSec)
            }
            catch {
                $totalTimeout = $null
            }
        }

        $retryValue = $null
        if ($serviceTable.ContainsKey('retry')) { $retryValue = $serviceTable['retry'] }
        if ($retryValue) {
            try {
                $retry = [Math]::Max(1, [int]$retryValue)
            }
            catch {
                $retry = 1
            }
        }

        $registry[$name] = [PSCustomObject]@{
            name         = $name
            transport    = $transport
            timeout      = $timeout
            idleTimeout  = $idleTimeout
            totalTimeout = $totalTimeout
            retry        = $retry
        }
    }

    if ($registry.Count -eq 0) {
        return
    }

    $script:McpRegistry = $registry

    if ($mcp.ContainsKey('defaultService') -and -not [string]::IsNullOrWhiteSpace($mcp.defaultService)) {
        $script:McpDefaultService = $mcp.defaultService
    }

    if ($script:McpDefaultService -and -not $script:McpRegistry.ContainsKey($script:McpDefaultService)) {
        Write-Host "[MCP] defaultService '$($script:McpDefaultService)' 未在 services 中定义，已忽略。" -ForegroundColor Yellow
        $script:McpDefaultService = $null
    }
}

function Get-McpService {
    <#
        .SYNOPSIS
            根据名称获取 MCP 服务配置，若未指定则尝试使用默认服务。
    #>
    param (
        [string]$Name
    )

    if (-not $script:McpRegistry -or $script:McpRegistry.Count -eq 0) {
        return $null
    }

    $targetName = $Name
    if ([string]::IsNullOrWhiteSpace($targetName)) {
        $targetName = $script:McpDefaultService
    }

    if ([string]::IsNullOrWhiteSpace($targetName)) {
        return $null
    }

    if (-not $script:McpRegistry.ContainsKey($targetName)) {
        return $null
    }

    return $script:McpRegistry[$targetName]
}

function Test-McpServiceAvailable {
    <#
        .SYNOPSIS
            检查当前是否存在可用的 MCP 服务。
    #>
    if (-not $script:McpRegistry) {
        return $false
    }

    return ($script:McpRegistry.Count -gt 0)
}

function Get-McpDefaultServiceName {
    <#
        .SYNOPSIS
            返回默认服务名称（若存在）。
    #>
    return $script:McpDefaultService
}

function Get-McpServicesSummaryText {
    <#
        .SYNOPSIS
            返回可用 MCP 服务的摘要文本，便于提示词注入或日志展示。
    #>

    if (-not (Test-McpServiceAvailable)) {
        return "当前未配置可用的 MCP 服务。"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($kvp in $script:McpRegistry.GetEnumerator()) {
        $name = $kvp.Key
        $svc = $kvp.Value
        $transport = $svc.transport.type
        $timeout = $svc.timeout
        $defaultTag = if ($script:McpDefaultService -and $script:McpDefaultService -eq $name) { "（默认）" } else { "" }
        # 避免在提示注入阶段主动请求远端，摘要仅包含本地配置
        $lines.Add("- $name$defaultTag：传输 $transport，超时 $timeout 秒") | Out-Null
    }

    return ($lines -join "`n")
}

function ConvertTo-McpParamsObject {
    <#
        .SYNOPSIS
            将输入参数转换为可序列化的对象，字符串尝试按 JSON 解析。
    #>
    param (
        [object]$Params
    )

    if ($null -eq $Params) {
        return $null
    }

    if ($Params -is [string]) {
        $text = $Params.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        $trimStart = $text.TrimStart()
        if (-not ($trimStart.StartsWith('{') -or $trimStart.StartsWith('['))) {
            return $text
        }

        try {
            return $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return $text
        }
    }

    return $Params
}

function Get-McpToolList {
    <#
        .SYNOPSIS
            请求服务返回可用工具列表（tools/list）。
    #>
    param (
        [string]$Service
    )

    return Invoke-McpRequest -Method 'tools/list' -Service $Service -RetryCount 1
}

function Invoke-McpToolCall {
    <#
        .SYNOPSIS
            以 tools/call 方式调用指定工具，避免把工具名误写成 JSON-RPC method。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [hashtable]$Arguments = @{},

        [string]$Service = $script:McpRegistry.defaultService,

        [int]$TimeoutSec = 60,

        [int]$RetryCount = 1
    )

    $params = @{
        name      = $ToolName
        arguments = $Arguments
    }

    return Invoke-McpRequest -Method 'tools/call' -Params $params -Service $Service -TimeoutSec $TimeoutSec -RetryCount $RetryCount
}

function Get-McpResourceList {
    <#
        .SYNOPSIS
            请求服务返回可用资源列表（resources/list）。
    #>
    param (
        [string]$Service
    )

    return Invoke-McpRequest -Method 'resources/list' -Service $Service -RetryCount 1
}

function Get-McpPromptList {
    <#
        .SYNOPSIS
            请求服务返回可用提示词模板列表（prompts/list）。
    #>
    param (
        [string]$Service
    )

    return Invoke-McpRequest -Method 'prompts/list' -Service $Service -RetryCount 1
}

function Invoke-McpSampling {
    <#
        .SYNOPSIS
            调用 MCP sampling 能力（若服务支持）。
    #>
    param (
        [string]$Service,
        [object]$Params
    )

    return Invoke-McpRequest -Method 'sampling' -Params $Params -Service $Service -RetryCount 1
}

function Invoke-McpRequest {
    <#
        .SYNOPSIS
            调用指定 MCP 服务，目前仅支持 SSE 传输。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $false)]
        [object]$Params,

        [string]$Service,

        [int]$TimeoutSec,

        [int]$IdleTimeoutSec,

        [int]$TotalTimeoutSec,

        [int]$RetryCount = 1,

        [int]$MaxReconnects = 1,

        [switch]$EnableCancellation
    )

    $effectiveEnableCancellation = $true
    if ($PSBoundParameters.ContainsKey('EnableCancellation')) {
        $effectiveEnableCancellation = [bool]$EnableCancellation
    }

    $requestedServiceName = $Service
    if ([string]::IsNullOrWhiteSpace($requestedServiceName)) {
        $requestedServiceName = $script:McpDefaultService
    }

    $serviceConfig = Get-McpService -Name $Service
    if (-not $serviceConfig) {
        $errorMessage = if ([string]::IsNullOrWhiteSpace($requestedServiceName)) {
            "未配置可用的 MCP 服务，请检查 mcp.config.json 并设置 defaultService。"
        } else {
            "未找到指定的 MCP 服务：$requestedServiceName"
        }
        return New-McpErrorResult -Service $requestedServiceName -Transport $null -ErrorMessage $errorMessage -ErrorCode 'ERR_MCP_SERVICE_NOT_FOUND'
    }

    if ([string]::IsNullOrWhiteSpace($Service) -and $script:McpDefaultService) {
        Write-Host "[MCP] 未指定服务，已使用默认服务 '$($serviceConfig.name)'。" -ForegroundColor DarkGray
    }

    $transport = $serviceConfig.transport
    $type = [string]$transport.type
    $normalizedType = $type.ToLowerInvariant()

    $finalTimeout = if ($TimeoutSec) { [Math]::Max(10, $TimeoutSec) } else { $serviceConfig.timeout }
    $serviceIdle = $null
    if ($serviceConfig.PSObject.Properties['idleTimeout'] -and $serviceConfig.idleTimeout) { $serviceIdle = $serviceConfig.idleTimeout }
    $serviceTotal = $null
    if ($serviceConfig.PSObject.Properties['totalTimeout'] -and $serviceConfig.totalTimeout) { $serviceTotal = $serviceConfig.totalTimeout }
    $serviceRetry = 0
    if ($serviceConfig.PSObject.Properties['retry'] -and $serviceConfig.retry) { $serviceRetry = $serviceConfig.retry }

    $finalIdleTimeout = if ($IdleTimeoutSec) { [Math]::Max(5, $IdleTimeoutSec) } elseif ($serviceIdle) { [Math]::Max(5, $serviceIdle) } else { $finalTimeout }
    $finalTotalTimeout = if ($TotalTimeoutSec) { [Math]::Max($finalTimeout, $TotalTimeoutSec) } elseif ($serviceTotal) { [Math]::Max($finalTimeout, $serviceTotal) } else { [Math]::Max($finalTimeout, $finalIdleTimeout) }

    $retrySource = 1
    if ($RetryCount -gt 0) {
        $retrySource = $RetryCount
    }
    elseif ($serviceRetry -gt 0) {
        $retrySource = $serviceRetry
    }
    $finalRetryCount = [Math]::Max(1, $retrySource)

    $payload = [PSCustomObject]@{
        jsonrpc = '2.0'
        id      = [guid]::NewGuid().ToString()
        method  = $Method
        params  = ConvertTo-McpParamsObject -Params $Params
    }

    $attempt = 0
    $lastError = $null
    while ($attempt -lt $finalRetryCount) {
        $attempt++
        switch ($normalizedType) {
            'sse' {
                $result = Invoke-McpSse -ServiceConfig $serviceConfig -Payload $payload -TimeoutSec $finalTimeout -IdleTimeoutSec $finalIdleTimeout -TotalTimeoutSec $finalTotalTimeout -MaxReconnects ([Math]::Max(0, $MaxReconnects)) -EnableCancellation:$effectiveEnableCancellation
                if ($result -and $result.success) {
                    return $result
                }
                $lastError = $result
                if ($attempt -lt $finalRetryCount) {
                    Write-Host "[MCP] 第 $attempt 次调用失败，准备重试..." -ForegroundColor DarkYellow
                }
                break
            }
            'websocket' {
                $result = Invoke-McpWebSocket -ServiceConfig $serviceConfig -Payload $payload -TimeoutSec $finalTimeout
                if ($result -and $result.success) { return $result }
                $lastError = $result
                break
            }
            'stdio' {
                $result = Invoke-McpStdio -ServiceConfig $serviceConfig -Payload $payload -TimeoutSec $finalTimeout
                if ($result -and $result.success) { return $result }
                $lastError = $result
                break
            }
            'streamablehttp' {
                $result = Invoke-McpStreamableHttp -ServiceConfig $serviceConfig -Payload $payload -TimeoutSec $finalTimeout
                if ($result -and $result.success) { return $result }
                $lastError = $result
                break
            }
            default {
                return New-McpErrorResult -Service $serviceConfig.name -Transport $type -ErrorMessage "传输类型 $type 尚未支持。" -ErrorCode 'ERR_MCP_TRANSPORT_UNSUPPORTED'
            }
        }
    }

    if ($lastError) { return $lastError }
    return New-McpErrorResult -Service $serviceConfig.name -Transport $type -ErrorMessage "MCP 调用失败但未捕获详细错误。" -ErrorCode 'ERR_MCP_UNKNOWN'
}

function Invoke-McpSse {
    <#
        .SYNOPSIS
            通过 SSE 通道调用 MCP 服务（带重连与限流）。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ServiceConfig,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Payload,

        [int]$TimeoutSec = 60,

        [int]$IdleTimeoutSec = 60,

        [int]$TotalTimeoutSec = 60,

        [int]$MaxReconnects = 1,

        [int]$MaxResponseBytes = 1048576,

        [switch]$EnableCancellation
    )

    $effectiveEnableCancellation = $true
    if ($PSBoundParameters.ContainsKey('EnableCancellation')) {
        $effectiveEnableCancellation = [bool]$EnableCancellation
    }

    # PowerShell 5 可能未默认加载 System.Net.Http，显式加载以避免类型缺失
    try {
        if (-not ("System.Net.Http.HttpClient" -as [type])) {
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }
    }
    catch {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage ("无法加载 System.Net.Http 依赖：" + $_.Exception.Message) -ErrorCode 'ERR_MCP_HTTP_DEPENDENCY'
    }

    $transport = $ServiceConfig.transport
    $url = $transport.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage "SSE 传输缺少 url 配置：$($ServiceConfig.name)" -ErrorCode 'ERR_MCP_MISSING_URL'
    }

    $baseUri = $null
    try { $baseUri = [System.Uri]$url } catch { $baseUri = $null }

    $httpMethodText = 'POST'
    if ($transport -is [hashtable]) {
        if ($transport.ContainsKey('method') -and -not [string]::IsNullOrWhiteSpace([string]$transport['method'])) {
            $httpMethodText = [string]$transport['method']
        }
    }
    elseif ($transport.PSObject.Properties['method'] -and -not [string]::IsNullOrWhiteSpace($transport.method)) {
        $httpMethodText = $transport.method
    }
    $httpMethod = [System.Net.Http.HttpMethod]::new($httpMethodText)

    $headers = @{}
    if ($transport -is [hashtable]) {
        if ($transport.ContainsKey('headers') -and $transport['headers']) {
            $headers = $transport['headers']
        }
    }
    elseif ($transport.PSObject.Properties['headers'] -and $transport.headers) {
        $headers = $transport.headers
    }

    $debugSseLines = $false
    if ($transport -is [hashtable]) {
        if ($transport.ContainsKey('debug') -and $transport['debug']) {
            $debugSseLines = [bool]$transport['debug']
        }
    }
    elseif ($transport.PSObject.Properties['debug']) {
        try { $debugSseLines = [bool]$transport.debug } catch { $debugSseLines = $false }
    }

    $payloadJson = $Payload | ConvertTo-Json -Depth 10 -Compress
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)

    $eventDataLines = New-Object System.Collections.Generic.List[string]
    $eventName = ''
    $eventId = ''
    $matchedPayload = $null
    $rawEvents = New-Object System.Collections.ArrayList
    $idleWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressAt = Get-Date
    $timedOut = $false
    $cancelled = $false

    $currentUrl = $url

    # 旧版 HTTP+SSE：GET /sse -> event:endpoint 给出 /messages?...，随后所有 JSON-RPC 都 POST 到该 endpoint
    $legacyMode = ($httpMethodText.Trim().ToUpperInvariant() -eq 'GET')
    $legacyPostEndpoint = $null
    $legacySendError = $null
    $legacyHttpClient = $null

    $legacyInitId = [guid]::NewGuid().ToString()
    $legacyInitSent = $false
    $legacyInitializedSent = $false
    $legacyRequestSent = $false

    $legacyInitRequest = [PSCustomObject]@{
        jsonrpc = '2.0'
        id      = $legacyInitId
        method  = 'initialize'
        params  = @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{
                name    = 'win-assistant'
                version = '1.0'
            }
        }
    }

    $legacyInitializedNotification = [PSCustomObject]@{
        jsonrpc = '2.0'
        method  = 'notifications/initialized'
        params  = @{}
    }

    $sendLegacyJsonRpc = {
        param(
            [object]$MessageObject
        )

        if (-not $legacyMode) { return }
        if ([string]::IsNullOrWhiteSpace($legacyPostEndpoint)) { return }
        if (-not $MessageObject) { return }

        $req2 = $null
        $resp2 = $null

        try {
            $json = $MessageObject | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            Write-McpTrace -Service $ServiceConfig.name -Transport 'sse' -Stage 'legacy-post' -Message '发送 JSON-RPC' -Metadata @{ url = $legacyPostEndpoint; preview = $json.Substring(0, [Math]::Min(200, $json.Length)) }

            $attemptSend = 0
            while ($attemptSend -lt 3) {
                $attemptSend++
                $req2 = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $legacyPostEndpoint)
                $null = $req2.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))

                foreach ($key in $headers.Keys) {
                    if ([string]::IsNullOrWhiteSpace($key)) { continue }
                    $req2.Headers.TryAddWithoutValidation($key, [string]$headers[$key]) | Out-Null
                }

                $req2.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
                $req2.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')

                $clientToUse = $legacyHttpClient
                if (-not $clientToUse) { throw "legacyHttpClient 未就绪，无法发送请求。" }
                $resp2 = $clientToUse.SendAsync($req2).GetAwaiter().GetResult()
                if ($resp2.IsSuccessStatusCode -or $resp2.StatusCode.value__ -eq 202) {
                    Set-Variable -Name legacySendError -Value $null -Scope 1
                    $legacySendError = $null
                    break
                }

                $bodyText = $null
                try { $bodyText = $resp2.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { $bodyText = $null }

                $legacySendError = "旧版 SSE 消息发送失败：$($resp2.StatusCode)"
                if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                    $legacySendError += " | 返回体：$bodyText"
                }
                Set-Variable -Name legacySendError -Value $legacySendError -Scope 1

                if ($bodyText -and $bodyText -like '*No transport found for sessionId*' -and $attemptSend -lt 3) {
                    Start-Sleep -Milliseconds 200
                    continue
                }
                break
            }
        }
        catch {
            $legacySendError = "旧版 SSE 消息发送异常：$($_.Exception.Message)"
            Set-Variable -Name legacySendError -Value $legacySendError -Scope 1
        }
        finally {
            if ($resp2) { $resp2.Dispose() }
            if ($req2) { $req2.Dispose() }
        }
    }

    $flushCurrentEvent = {
        if ($eventDataLines.Count -eq 0) {
            return $false
        }

        $dataText = ($eventDataLines -join "`n")
        if ($dataText.Length -gt $MaxResponseBytes) {
            $matchedPayload = New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage "收到的事件数据超出限制（>${MaxResponseBytes} 字节），为保护会话已中止。" -ErrorCode 'ERR_MCP_RESPONSE_TOO_LARGE'
            return $true
        }
        if ($dataText -match '(?m)^\s*\[BLOB\]') {
            $matchedPayload = New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage "服务返回了二进制数据，当前客户端未支持解析（事件ID：$eventId）。" -ErrorCode 'ERR_MCP_BINARY_UNSUPPORTED'
            return $true
        }

        $parsed = $null
        $dataTrim = $dataText
        if (-not (Test-StringEmpty -Value $dataTrim)) {
            $dataTrim = $dataTrim.TrimStart()
        }
        if (-not (Test-StringEmpty -Value $dataTrim) -and ($dataTrim.StartsWith('{') -or $dataTrim.StartsWith('['))) {
            try {
                $parsed = $dataText | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $parsed = $null
            }
        }

        $eventRecord = [PSCustomObject]@{
            name    = $eventName
            id      = $eventId
            dataRaw = $dataText
            data    = $parsed
        }
        $null = $rawEvents.Add($eventRecord)

        # 旧版 HTTP+SSE：SSE 连接会先返回 endpoint 事件，data 中给出 POST 入口（常见为 /messages?sessionId=...）
        if ($legacyMode -and -not $legacyPostEndpoint -and $eventName -eq 'endpoint' -and -not [string]::IsNullOrWhiteSpace($dataText)) {
            $endpointText = $dataText.Trim()
            if ($endpointText -match '^\s*/') {
                if ($baseUri) {
                    $endpointText = (New-Object System.Uri($baseUri, $endpointText)).AbsoluteUri
                }
            }
            Set-Variable -Name legacyPostEndpoint -Value $endpointText -Scope 1
            $legacyPostEndpoint = $endpointText
            Write-McpTrace -Service $ServiceConfig.name -Transport 'sse' -Stage 'legacy-endpoint' -Message '收到 endpoint，准备初始化' -Metadata @{ endpoint = $legacyPostEndpoint }
            if (-not $legacyInitSent) {
                Start-Sleep -Milliseconds 100
                & $sendLegacyJsonRpc $legacyInitRequest
                Set-Variable -Name legacyInitSent -Value $true -Scope 1
                $legacyInitSent = $true
            }

            $eventDataLines.Clear()
            $eventName = ''
            $eventId = ''
            return $false
        }

        $matchedId = $false
        if ($parsed -and $parsed.PSObject.Properties['id'] -and $parsed.id -eq $Payload.id) {
            $matchedId = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace($eventId) -and $eventId -eq $Payload.id) {
            $matchedId = $true
        }

        $hasResult = $parsed -and $parsed.PSObject.Properties['result']
        $hasError = $parsed -and $parsed.PSObject.Properties['error']

        # 旧版 HTTP+SSE：等待 initialize 响应后发送 initialized + 实际请求
        if ($legacyMode -and $legacyInitSent -and -not $legacyRequestSent -and
            $parsed -and $parsed.PSObject.Properties['id'] -and $parsed.id -eq $legacyInitId) {
            if ($hasError) {
                $errText = ConvertFrom-McpErrorObjectToMessage -ErrorObject $parsed.error
                $matchedPayload = New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'sse' -Data $parsed -ErrorMessage $errText -ErrorCode 'ERR_MCP_REMOTE_ERROR'
                Set-Variable -Name matchedPayload -Value $matchedPayload -Scope 1
                return $true
            }
            if ($hasResult) {
                Write-McpTrace -Service $ServiceConfig.name -Transport 'sse' -Stage 'legacy-init' -Message 'initialize 已完成，发送 initialized + 请求' -Metadata @{ initId = $legacyInitId }
                if (-not $legacyInitializedSent) {
                    & $sendLegacyJsonRpc $legacyInitializedNotification
                    Set-Variable -Name legacyInitializedSent -Value $true -Scope 1
                    $legacyInitializedSent = $true
                }
                if (-not $legacyRequestSent) {
                    & $sendLegacyJsonRpc $Payload
                    Set-Variable -Name legacyRequestSent -Value $true -Scope 1
                    $legacyRequestSent = $true
                }
            }
        }

        # 匹配当前请求响应
        if ($parsed -and $matchedId) {
            if ($hasError) {
                $errText = ConvertFrom-McpErrorObjectToMessage -ErrorObject $parsed.error
                $matchedPayload = New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'sse' -Data $parsed -ErrorMessage $errText -ErrorCode 'ERR_MCP_REMOTE_ERROR'
                Set-Variable -Name matchedPayload -Value $matchedPayload -Scope 1
                return $true
            }
            if ($hasResult) {
                $matchedPayload = New-McpResult -Success:$true -Service $ServiceConfig.name -Transport 'sse' -Data $parsed.result
                Set-Variable -Name matchedPayload -Value $matchedPayload -Scope 1
                return $true
            }
        }

        $eventDataLines.Clear()
        $eventName = ''
        $eventId = ''
        return $false
    }

    $attemptIndex = 0
    while ($attemptIndex -le $MaxReconnects) {
        $attemptIndex++

        $handler = $null
        $client = $null
        $request = $null
        $response = $null
        $stream = $null
        $reader = $null
        $timedOut = $false
        $idleWatch.Restart()

        Write-McpTrace -Service $ServiceConfig.name -Transport 'sse' -Stage "connect" -Message "SSE 第 $attemptIndex 次连接" -Metadata @{ url = $currentUrl }

        try {
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $client = [System.Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromMilliseconds(-1)
            if ($legacyMode) {
                $legacyHttpClient = $client
            }

            $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $currentUrl)
            $null = $request.Headers.Accept.Clear()
            $null = $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('text/event-stream'))
            foreach ($key in $headers.Keys) {
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                $request.Headers.TryAddWithoutValidation($key, [string]$headers[$key]) | Out-Null
            }

            if (-not $httpMethod.Equals([System.Net.Http.HttpMethod]::Get)) {
                $request.Content = [System.Net.Http.ByteArrayContent]::new($payloadBytes)
                $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
            }

            try {
                $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            }
            catch {
                if ($attemptIndex -le $MaxReconnects) {
                    Write-Host "[MCP] SSE 连接失败，尝试重连 ($attemptIndex/$MaxReconnects)..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                    continue
                }
                return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage ("SSE 请求发送失败：$($_.Exception.Message)") -ErrorCode 'ERR_MCP_REQUEST_FAILED'
            }

            if (-not $response.IsSuccessStatusCode) {
                if ($attemptIndex -le $MaxReconnects) {
                    Write-Host "[MCP] SSE 状态异常，尝试重连 ($attemptIndex/$MaxReconnects)..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                    continue
                }
                return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage "SSE 响应状态异常：$($response.StatusCode)（url=$currentUrl，method=$httpMethodText）" -ErrorCode 'ERR_MCP_BAD_STATUS'
            }

            try {
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                if ($stream -and $stream.CanTimeout) {
                    $stream.ReadTimeout = $TimeoutSec * 1000
                }
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
                $canReadKeys = $false
                if ($effectiveEnableCancellation) {
                    try {
                        $canReadKeys = -not [Console]::IsInputRedirected
                    }
                    catch {
                        $canReadKeys = $false
                    }
                    if ($canReadKeys) {
                        Write-Host "[MCP] 接收中...按 q 或 Ctrl+C 可取消。" -ForegroundColor DarkGray
                    }
                }
            }
            catch {
                if ($attemptIndex -le $MaxReconnects) {
                    Write-Host "[MCP] SSE 流初始化失败，尝试重连 ($attemptIndex/$MaxReconnects)..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                    continue
                }
                return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage ("SSE 流初始化失败：$($_.Exception.Message)") -ErrorCode 'ERR_MCP_STREAM_INIT'
            }

            $pendingReadTask = $null
            $debugLineCount = 0
            while ($true) {
                $keyAvailable = $false
                if ($effectiveEnableCancellation -and $canReadKeys) {
                    try { $keyAvailable = [Console]::KeyAvailable } catch { $keyAvailable = $false }
                }
                if ($effectiveEnableCancellation -and $canReadKeys -and $keyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'C' -and $key.Modifiers -band [ConsoleModifiers]::Control) {
                        $cancelled = $true
                        break
                    }
                    if ($key.KeyChar -eq 'q') {
                        $cancelled = $true
                        break
                    }
                }

                if ($idleWatch.Elapsed.TotalSeconds -ge $IdleTimeoutSec -or $totalWatch.Elapsed.TotalSeconds -ge $TotalTimeoutSec) {
                    $timedOut = $true
                    break
                }

                $line = $null
                try {
                    if (-not $pendingReadTask) {
                        $pendingReadTask = $reader.ReadLineAsync()
                    }
                    if (-not $pendingReadTask.Wait(1000)) {
                        continue
                    }
                    $line = $pendingReadTask.Result
                    $pendingReadTask = $null
                }
                catch {
                    break
                }

                if ($null -eq $line) { break }
                $idleWatch.Restart()
                $debugLineCount++
                if ($debugSseLines -and $debugLineCount -le 30) {
                    Write-McpTrace -Service $ServiceConfig.name -Transport 'sse' -Stage 'sse-line' -Message $line -Metadata $null
                }
                $now = Get-Date
                if (($now - $lastProgressAt).TotalSeconds -ge 5) {
                    $elapsed = [Math]::Round($totalWatch.Elapsed.TotalSeconds, 1)
                    Write-Host "[MCP] 接收中... (服务: $($ServiceConfig.name), 已用时 ${elapsed}s)" -ForegroundColor DarkGray
                    $lastProgressAt = $now
                }

                if ($line -eq '') {
                    if (& $flushCurrentEvent) {
                        break
                    }
                    continue
                }

                if ($line.StartsWith(':')) {
                    # SSE 心跳/注释
                    continue
                }

                if ($line.StartsWith('data:')) {
                    $eventDataLines.Add($line.Substring(5).TrimStart()) | Out-Null
                    continue
                }

                if ($line.StartsWith('event:')) {
                    $eventName = $line.Substring(6).TrimStart()
                    continue
                }

                if ($line.StartsWith('id:')) {
                    $eventId = $line.Substring(3).TrimStart()
                    continue
                }
            }
        }
        finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($request) { $request.Dispose() }
            if ($client) { $client.Dispose() }
            if ($handler) { $handler.Dispose() }
        }

        if ($matchedPayload) { break }

        if ($cancelled) {
            break
        }

        if ($timedOut -and $attemptIndex -le $MaxReconnects) {
            Write-Host "[MCP] SSE 超时，尝试重连 ($attemptIndex/$MaxReconnects)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 1
            continue
        }

        if (-not $matchedPayload -and $attemptIndex -le $MaxReconnects) {
            Write-Host "[MCP] SSE 连接结束但未收到结果，尝试重连 ($attemptIndex/$MaxReconnects)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 1
            continue
        }

        break
    }

    if ($cancelled) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage "用户中断了 SSE 读取。" -ErrorCode 'ERR_MCP_CANCELLED'
    }

    if ($legacyMode -and -not (Test-StringEmpty -Value $legacySendError) -and -not $matchedPayload) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage $legacySendError -ErrorCode 'ERR_MCP_REQUEST_FAILED'
    }

    if (-not $matchedPayload) {
        & $flushCurrentEvent | Out-Null
    }

    if ($timedOut -and -not $matchedPayload) {
        $helpText = "服务响应超时。建议检查网络连接、确认服务状态，或在 mcp.config.json 调整 timeoutSec/idleTimeoutSec。"
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage $helpText -ErrorCode 'ERR_MCP_TIMEOUT'
    }

    if ($matchedPayload) {
        return $matchedPayload
    }

    $noResultMessage = 'SSE 未返回匹配的响应或超时结束。'
    return New-McpErrorResult -Service $ServiceConfig.name -Transport 'sse' -ErrorMessage $noResultMessage -ErrorCode 'ERR_MCP_NO_RESULT'
}

Initialize-McpPrompt

Export-ModuleMember -Function * -Alias * -Variable *

function Invoke-McpStreamableHttp {
    <#
        .SYNOPSIS
            通过 streamableHttp 通道调用 MCP 服务：发送 HTTP 请求并解析 JSON 结果。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ServiceConfig,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Payload,

        [int]$TimeoutSec = 60
    )

    $transport = $ServiceConfig.transport
    $url = $transport.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'streamablehttp' -ErrorMessage "streamableHttp 传输缺少 url 配置：$($ServiceConfig.name)" -ErrorCode 'ERR_MCP_MISSING_URL'
    }

    $httpMethodText = 'POST'
    if ($transport.PSObject.Properties['method'] -and -not [string]::IsNullOrWhiteSpace($transport.method)) {
        $httpMethodText = $transport.method
    }

    $headers = @{}
    if ($transport.PSObject.Properties['headers'] -and $transport.headers) {
        $headers = $transport.headers
    }

    $payloadJson = $Payload | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)

    $invokeParams = @{
        Uri         = $url
        Method      = $httpMethodText
        TimeoutSec  = [Math]::Max(5, $TimeoutSec)
        ErrorAction = 'Stop'
        Headers     = $headers
    }
    if (-not $invokeParams.Headers.ContainsKey('Accept')) {
        $invokeParams.Headers['Accept'] = 'application/json'
    }
    if (-not $invokeParams.Headers.ContainsKey('Content-Type')) {
        $invokeParams.Headers['Content-Type'] = 'application/json'
    }

    if (-not $httpMethodText.ToUpperInvariant().Equals('GET')) {
        $invokeParams['Body'] = $bytes
    }

    try {
        $resp = Invoke-WebRequest @invokeParams
        $text = ''
        if ($resp.Content) {
            $text = $resp.Content
        }
        elseif ($resp.RawContent) {
            $text = $resp.RawContent
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'streamablehttp' -ErrorMessage "HTTP 响应为空。" -ErrorCode 'ERR_MCP_HTTP_EMPTY'
        }

        $parsed = $null
        try {
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'streamablehttp' -ErrorMessage "HTTP 返回非 JSON：$text" -ErrorCode 'ERR_MCP_HTTP_INVALID'
        }

        if ($parsed.PSObject.Properties['error']) {
            return New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'streamablehttp' -Data $parsed -ErrorMessage ([string]$parsed.error) -ErrorCode 'ERR_MCP_REMOTE_ERROR'
        }
        if ($parsed.PSObject.Properties['result']) {
            return New-McpResult -Success:$true -Service $ServiceConfig.name -Transport 'streamablehttp' -Data $parsed.result
        }

        # 兼容流式返回 {success, data}
        if ($parsed.PSObject.Properties['success'] -and $parsed.PSObject.Properties['data']) {
            $succ = [bool]$parsed.success
            if ($succ) {
                return New-McpResult -Success:$true -Service $ServiceConfig.name -Transport 'streamablehttp' -Data $parsed.data
            }
            else {
                return New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'streamablehttp' -Data $parsed.data -ErrorMessage ([string]($parsed.error)) -ErrorCode 'ERR_MCP_REMOTE_ERROR'
            }
        }

        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'streamablehttp' -ErrorMessage "HTTP 返回缺少 result/error 字段。" -ErrorCode 'ERR_MCP_SCHEMA_INVALID'
    }
    catch {
        $status = $null
        $body = $null
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $status = $_.Exception.Response.StatusCode
            }
            if ($_.Exception.Response) {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                }
            }
        }
        catch { $status = $null }
        $msg = if ($status) { "HTTP 状态异常：$status，详情：$($_.Exception.Message)" } else { "HTTP 调用异常：$($_.Exception.Message)" }
        if ($body) { $msg += " | 返回体：$body" }
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'streamablehttp' -ErrorMessage $msg -ErrorCode 'ERR_MCP_HTTP_EXCEPTION'
    }
}

function Invoke-McpStdio {
    <#
        .SYNOPSIS
            通过 stdio 通道调用 MCP 服务：启动指定进程，写入 JSON 载荷，从 stdout 读取 JSON 结果。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ServiceConfig,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Payload,

        [int]$TimeoutSec = 60
    )

    $transport = $ServiceConfig.transport
    $command = $transport.command
    if ([string]::IsNullOrWhiteSpace($command)) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 传输缺少 command 配置：$($ServiceConfig.name)" -ErrorCode 'ERR_MCP_MISSING_COMMAND'
    }

    $processArgs = @()
    if ($transport.PSObject.Properties['args'] -and $transport.args) {
        $processArgs = @($transport.args) -join ' '
    }

    $payloadJson = $Payload | ConvertTo-Json -Depth 10 -Compress

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $command
    $psi.Arguments = $processArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    if ($transport.PSObject.Properties['env'] -and $transport.env) {
        foreach ($key in $transport.env.Keys) {
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $psi.Environment[$key] = [string]$transport.env[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        $null = $process.Start()
        $process.StandardInput.Write($payloadJson)
        $process.StandardInput.Close()

        $finished = $process.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            try { $process.Kill() } catch {}
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 调用超时（${TimeoutSec}s）" -ErrorCode 'ERR_MCP_TIMEOUT'
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        if ($process.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($stderr)) {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 进程错误：$stderr" -ErrorCode 'ERR_MCP_STDIO_EXIT'
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 无输出" -ErrorCode 'ERR_MCP_STDIO_EMPTY'
        }

        $parsed = $null
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 输出非 JSON：$stdout" -ErrorCode 'ERR_MCP_STDIO_INVALID'
        }

        if ($parsed.PSObject.Properties['error']) {
            return New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'stdio' -Data $parsed -ErrorMessage ([string]$parsed.error) -ErrorCode 'ERR_MCP_REMOTE_ERROR'
        }
        if ($parsed.PSObject.Properties['result']) {
            return New-McpResult -Success:$true -Service $ServiceConfig.name -Transport 'stdio' -Data $parsed.result
        }

        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage "stdio 输出缺少 result/error 字段。" -ErrorCode 'ERR_MCP_SCHEMA_INVALID'
    }
    catch {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'stdio' -ErrorMessage ("stdio 调用异常：" + $_.Exception.Message) -ErrorCode 'ERR_MCP_STDIO_EXCEPTION'
    }
    finally {
        if ($process) { $process.Dispose() }
    }
}

function Invoke-McpWebSocket {
    <#
        .SYNOPSIS
            通过 WebSocket 调用 MCP 服务，发送一次 payload，等待 JSON 响应。
    #>
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ServiceConfig,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Payload,

        [int]$TimeoutSec = 60
    )

    $transport = $ServiceConfig.transport
    $url = $transport.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'websocket' -ErrorMessage "websocket 传输缺少 url 配置：$($ServiceConfig.name)" -ErrorCode 'ERR_MCP_MISSING_URL'
    }

    $client = [System.Net.WebSockets.ClientWebSocket]::new()
    if ($transport.PSObject.Properties['headers'] -and $transport.headers) {
        foreach ($key in $transport.headers.Keys) {
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $client.Options.SetRequestHeader($key, [string]$transport.headers[$key])
        }
    }

    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutSec * 1000)
    $payloadJson = $Payload | ConvertTo-Json -Depth 10 -Compress
    $sendBuffer = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
    $sendSegment = [ArraySegment[byte]]::new($sendBuffer)

    $receiveBuffer = New-Object System.Byte[] (1024 * 64)
    $received = New-Object System.Text.StringBuilder

    try {
        $client.ConnectAsync([System.Uri]$url, $cts.Token).Wait()
        Write-McpTrace -Service $ServiceConfig.name -Transport 'websocket' -Stage "connect" -Message "已连接 websocket" -Metadata @{ url = $url }

        $client.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()

        while ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $result = $client.ReceiveAsync([ArraySegment[byte]]::new($receiveBuffer), $cts.Token).Result
            if ($result.Count -gt 0) {
                $received.Append([System.Text.Encoding]::UTF8.GetString($receiveBuffer, 0, $result.Count)) | Out-Null
            }
            if ($result.EndOfMessage) { break }
        }

        $text = $received.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'websocket' -ErrorMessage "websocket 未返回任何数据。" -ErrorCode 'ERR_MCP_WS_EMPTY'
        }

        $parsed = $null
        try {
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return New-McpErrorResult -Service $ServiceConfig.name -Transport 'websocket' -ErrorMessage "websocket 返回非 JSON：$text" -ErrorCode 'ERR_MCP_WS_INVALID'
        }

        if ($parsed.PSObject.Properties['error']) {
            return New-McpResult -Success:$false -Service $ServiceConfig.name -Transport 'websocket' -Data $parsed -ErrorMessage ([string]$parsed.error) -ErrorCode 'ERR_MCP_REMOTE_ERROR'
        }
        if ($parsed.PSObject.Properties['result']) {
            return New-McpResult -Success:$true -Service $ServiceConfig.name -Transport 'websocket' -Data $parsed.result
        }

        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'websocket' -ErrorMessage "websocket 返回缺少 result/error 字段。" -ErrorCode 'ERR_MCP_SCHEMA_INVALID'
    }
    catch {
        return New-McpErrorResult -Service $ServiceConfig.name -Transport 'websocket' -ErrorMessage ("websocket 调用异常：" + $_.Exception.Message) -ErrorCode 'ERR_MCP_WS_EXCEPTION'
    }
    finally {
        if ($client) { $client.Dispose() }
        if ($cts) { $cts.Dispose() }
    }
}
