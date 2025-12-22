# modules/executor.ps1
# 兼容入口：保留原文件名，实际实现迁移到 executor.psm1

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'executor.psm1'
Import-Module -Name $modulePath -Force -DisableNameChecking

