@echo off
chcp 65001 >nul
title Windows AI 助理
echo 正在启动Windows AI 助理...
powershell -ExecutionPolicy Bypass -File "%~dp0core.ps1"
