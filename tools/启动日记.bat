@echo off
chcp 65001 >nul
setlocal
title 日记平台启动器
echo ============================================
echo   日记平台 —— 一键启动
echo ============================================
echo.

set "ROOT=%~dp0.."
set "PGBIN=C:\Program Files\PostgreSQL\17\bin"

echo [1/4] 启动数据库...
if exist "%PGBIN%\pg_isready.exe" (
  "%PGBIN%\pg_isready.exe" -h 127.0.0.1 -p 5544 >nul 2>&1
  if errorlevel 1 (
    "%PGBIN%\pg_ctl.exe" -D "C:\dev\pg-data" -o "-p 5544 -c listen_addresses=127.0.0.1" -l "C:\dev\pg-log.txt" -w start
  ) else (
    echo       数据库已在运行
  )
) else (
  echo       未找到 PostgreSQL 17，请先安装
  pause
  exit /b 1
)

echo [2/4] 检查服务端依赖...
cd /d "%ROOT%\server"
if not exist "node_modules" (
  echo       首次运行，正在安装依赖（约 1 分钟）...
  call npm install --no-audit --no-fund
)

echo [3/4] 启动服务端...
start "日记服务端" /min cmd /c "npm start"

echo       等待服务端就绪...
set /a tries=0
:waitloop
timeout /t 2 >nul
powershell -NoProfile -Command "try { (Invoke-WebRequest -Uri 'http://127.0.0.1:8080/healthz' -TimeoutSec 2 -UseBasicParsing).StatusCode } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
  set /a tries+=1
  if %tries% lss 15 goto waitloop
  echo       服务端启动超时，请查看“日记服务端”窗口的报错
  pause
  exit /b 1
)
echo       服务端就绪：http://127.0.0.1:8080/healthz

echo [4/4] 启动客户端...
start "" "%ROOT%\dist\RiJi-Windows-x64\riji_client.exe"

echo.
echo 完成。关闭本窗口不会停止服务端。
echo 如需停止服务端，请关闭任务栏中的“日记服务端”窗口。
echo.
timeout /t 5 >nul
endlocal
