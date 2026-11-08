@echo off
chcp 65001 >nul
title 日记平台 · 安装
echo.
echo   正在准备安装，请稍候…
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1"
echo.
pause
