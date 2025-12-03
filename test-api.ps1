# test-api.ps1 - API连接测试脚本

Write-Host "=== OpenAI 兼容 API 测试工具 ===" -ForegroundColor Cyan
Write-Host ""

. "$PSScriptRoot\modules\common.ps1"

# 读取配置
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

Write-Host "[配置信息]" -ForegroundColor Yellow
Write-Host "API URL: $($config.apiUrl)" -ForegroundColor Gray
Write-Host "模型: $($config.model)" -ForegroundColor Gray

$apiKeyPreview = "（未配置）"
if ($config.apiKey -and -not (Test-StringEmpty -Value $config.apiKey)) {
    $previewLength = [Math]::Min(20, $config.apiKey.Length)
    $apiKeyPreview = $config.apiKey.Substring(0, $previewLength)
    if ($previewLength -lt $config.apiKey.Length) {
        $apiKeyPreview = "$apiKeyPreview..."
    }
}

Write-Host "API Key: $apiKeyPreview" -ForegroundColor Gray
Write-Host ""

# 测试1：最简单的请求
Write-Host "[测试1] 发送最简单的请求..." -ForegroundColor Green

$simpleBody = @{
    model = $config.model
    messages = @(
        @{
            role = "user"
            content = "Hello"
        }
    )
} | ConvertTo-Json -Depth 10

$headers = @{
    "Authorization" = "Bearer $($config.apiKey)"
    "Content-Type" = "application/json"
}

Write-Host "请求体:" -ForegroundColor DarkGray
Write-Host $simpleBody -ForegroundColor DarkGray
Write-Host ""

try {
    $response = Invoke-WebRequest -Uri $config.apiUrl -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($simpleBody)) -ErrorAction Stop
    Write-Host "[成功] HTTP状态码: $($response.StatusCode)" -ForegroundColor Green
    Write-Host "响应内容:" -ForegroundColor Green
    Write-Host $response.Content -ForegroundColor Gray
}
catch {
    Write-Host "[失败] 请求失败" -ForegroundColor Red
    Write-Host "错误消息: $($_.Exception.Message)" -ForegroundColor Red

    $httpError = Format-HttpError -Exception $_.Exception
    if ($httpError.StatusCode) {
        Write-Host "HTTP状态码: $($httpError.StatusCode)" -ForegroundColor Red
    }

    if ($httpError.Body) {
        Write-Host "详细错误:" -ForegroundColor Red
        Write-Host $httpError.Body -ForegroundColor DarkRed
    }
    elseif ($httpError.StatusCode) {
        Write-Host "无法读取错误详情" -ForegroundColor DarkRed
    }
}

Write-Host ""
Write-Host "[测试2] 测试带temperature参数的请求..." -ForegroundColor Green

$bodyWithTemp = @{
    model = $config.model
    messages = @(
        @{
            role = "user"
            content = "Say hello in Chinese"
        }
    )
    temperature = 0.7
} | ConvertTo-Json -Depth 10

try {
    $response2 = Invoke-WebRequest -Uri $config.apiUrl -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyWithTemp)) -ErrorAction Stop
    Write-Host "[成功] HTTP状态码: $($response2.StatusCode)" -ForegroundColor Green
    Write-Host "响应内容:" -ForegroundColor Green
    Write-Host $response2.Content -ForegroundColor Gray
}
catch {
    Write-Host "[失败] 请求失败" -ForegroundColor Red
    Write-Host "错误消息: $($_.Exception.Message)" -ForegroundColor Red

    $httpError = Format-HttpError -Exception $_.Exception
    if ($httpError.StatusCode) {
        Write-Host "HTTP状态码: $($httpError.StatusCode)" -ForegroundColor Red
    }

    if ($httpError.Body) {
        Write-Host "详细错误:" -ForegroundColor Red
        Write-Host $httpError.Body -ForegroundColor DarkRed
    }
    elseif ($httpError.StatusCode) {
        Write-Host "无法读取错误详情" -ForegroundColor DarkRed
    }
}

Write-Host ""
Write-Host "=== 测试完成 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "如果两个测试都失败，可能的原因：" -ForegroundColor Yellow
Write-Host "1. API Key 无效或已过期" -ForegroundColor Gray
Write-Host "2. API URL 不正确（应该是完整的聊天端点URL）" -ForegroundColor Gray
Write-Host "3. 模型名称不被该API服务支持" -ForegroundColor Gray
Write-Host "4. API服务商的具体参数要求不同" -ForegroundColor Gray
Write-Host "5. 需要额外的请求头（如某些服务需要 HTTP-Referer）" -ForegroundColor Gray
