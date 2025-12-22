# modules/mcp.ps1
# 兼容入口：保留原文件名，实际实现迁移到 mcp.psm1

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'mcp.psm1'
Import-Module -Name $modulePath -Force -DisableNameChecking

