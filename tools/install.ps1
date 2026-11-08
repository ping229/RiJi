# RiJi 日记平台 · Windows 一键安装
#
# 这个脚本面向不懂开发的人：双击「安装.bat」即可，不需要记命令。
# 它会依次完成：检查环境 → 准备数据库 → 安装依赖 → 建表 → 启动服务端 → 打印登录信息。
#
# 所有步骤都是幂等的：重复运行不会破坏已有数据。

$ErrorActionPreference = 'Stop'

function Write-Step($n, $total, $text) {
  Write-Host ""
  Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
  Write-Host "  [$n/$total] $text" -ForegroundColor Cyan
  Write-Host "────────────────────────────────────────────" -ForegroundColor DarkGray
}

function Write-Ok($text)   { Write-Host "  ✓ $text" -ForegroundColor Green }
function Write-Warn2($text){ Write-Host "  ! $text" -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host "  ✗ $text" -ForegroundColor Red }

$root = Split-Path -Parent $PSScriptRoot
$serverDir = Join-Path $root 'server'
$pgData = if ($env:RJJ_PGDATA) { $env:RJJ_PGDATA } else { 'C:\dev\pg-data' }
$pgPort = 5544
$serverPort = 8080

Write-Host ""
Write-Host "  RiJi 日记平台 · 安装程序" -ForegroundColor White
Write-Host "  安装目录：$root" -ForegroundColor DarkGray

# ---------------------------------------------------------------- 1. 检查环境

Write-Step 1 6 "检查运行环境"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Err "没有找到 Node.js"
  Write-Host "    请先安装 Node.js 18 或更高版本：https://nodejs.org/zh-cn" -ForegroundColor White
  Read-Host "    安装完成后按回车重新运行"
  exit 1
}
$nodeVersion = (& node --version).Trim()
Write-Ok "Node.js $nodeVersion"

$pgBin = $null
$candidates = @(
  'C:\Program Files\PostgreSQL\17\bin',
  'C:\Program Files\PostgreSQL\16\bin',
  'C:\Program Files\PostgreSQL\15\bin'
) + (Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'bin' })

foreach ($c in $candidates) {
  if (Test-Path (Join-Path $c 'pg_ctl.exe')) { $pgBin = $c; break }
}
if (-not $pgBin) {
  Write-Err "没有找到 PostgreSQL"
  Write-Host "    请先安装 PostgreSQL 16 或更高版本：https://www.postgresql.org/download/windows/" -ForegroundColor White
  Write-Host "    安装时的密码请自己记好（本程序不会用到它，但卸载时需要）" -ForegroundColor DarkGray
  Read-Host "    安装完成后按回车重新运行"
  exit 1
}
Write-Ok "PostgreSQL（$pgBin）"

# ------------------------------------------------------------ 2. 准备数据库

Write-Step 2 6 "准备数据库（独立实例，不影响系统里已有的数据库）"

$ready = & (Join-Path $pgBin 'pg_isready.exe') -h 127.0.0.1 -p $pgPort 2>&1
if ($LASTEXITCODE -ne 0) {
  if (-not (Test-Path (Join-Path $pgData 'PG_VERSION'))) {
    Write-Host "  首次安装，正在初始化数据库目录：$pgData" -ForegroundColor DarkGray
    New-Item -ItemType Directory -Force (Split-Path $pgData) | Out-Null
    & (Join-Path $pgBin 'initdb.exe') -D $pgData -U diary --auth=trust -E UTF8 --locale=C 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "数据库初始化失败"; exit 1 }
    Write-Ok "数据库目录已创建"
  }
  & (Join-Path $pgBin 'pg_ctl.exe') -D $pgData -o "-p $pgPort -c listen_addresses=127.0.0.1" -l (Join-Path $pgData 'server.log') -w start 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  Write-Ok "数据库已启动（端口 $pgPort）"
} else {
  Write-Ok "数据库已在运行（端口 $pgPort）"
}

$dbExists = (& (Join-Path $pgBin 'psql.exe') -h 127.0.0.1 -p $pgPort -U diary -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='riji';" 2>&1 | Out-String).Trim()
if ($dbExists -ne '1') {
  & (Join-Path $pgBin 'psql.exe') -h 127.0.0.1 -p $pgPort -U diary -d postgres -c "CREATE DATABASE riji;" 2>&1 | Out-Null
  Write-Ok "已创建数据库 riji"
} else {
  Write-Ok "数据库 riji 已存在"
}

# ---------------------------------------------------------------- 3. 安装依赖

Write-Step 3 6 "安装服务端依赖（首次约需 1 分钟）"

Push-Location $serverDir
$env:npm_config_registry = 'https://registry.npmmirror.com'
if (-not (Test-Path 'node_modules')) {
  & npm.cmd install --no-audit --no-fund 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Err "依赖安装失败，请检查网络"; Pop-Location; exit 1 }
  Write-Ok "依赖已安装"
} else {
  Write-Ok "依赖已存在，跳过"
}

# ------------------------------------------------------------------ 4. 建表

Write-Step 4 6 "初始化数据表"

$env:RJJ_DATABASE_URL = "postgres://diary@127.0.0.1:$pgPort/riji"
& npm.cmd run migrate 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Err "建表失败"; Pop-Location; exit 1 }
Write-Ok "数据表已就绪"
Pop-Location

# ------------------------------------------------------------ 5. 启动服务端

Write-Step 5 6 "启动服务端"

$listening = Get-NetTCPConnection -LocalPort $serverPort -State Listen -ErrorAction SilentlyContinue
if ($listening) {
  Write-Ok "服务端已在运行（端口 $serverPort）"
} else {
  Start-Process -FilePath 'powershell' -ArgumentList @(
    '-NoProfile', '-Command',
    "Set-Location '$serverDir'; `$env:RJJ_PORT='$serverPort'; `$env:RJJ_DATABASE_URL='$env:RJJ_DATABASE_URL'; npm start *> '$serverDir\var\server.log'"
  ) -WindowStyle Hidden
  Write-Host "  正在启动…" -ForegroundColor DarkGray
  $ok = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:$serverPort/healthz" -TimeoutSec 2 -UseBasicParsing
      if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch { }
  }
  if (-not $ok) {
    Write-Err "服务端启动失败，日志在：$serverDir\var\server.log"
    Read-Host "按回车退出"
    exit 1
  }
  Write-Ok "服务端已启动"
}

# ------------------------------------------------------- 6. 创建快捷方式并收尾

Write-Step 6 6 "创建桌面快捷方式"

$ws = New-Object -ComObject WScript.Shell
$clientExe = Join-Path $root 'dist\RiJi-Windows-x64\riji_client.exe'
if (-not (Test-Path $clientExe)) { $clientExe = Join-Path $root 'client\build\windows\x64\runner\Release\riji_client.exe' }

if (Test-Path $clientExe) {
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '日记.lnk'
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = $clientExe
  $sc.WorkingDirectory = Split-Path $clientExe
  $sc.Description = '日记'
  $sc.Save()
  Write-Ok "桌面已创建「日记」快捷方式"
} else {
  Write-Warn2 "没有找到客户端程序，跳过快捷方式"
}

$adminFile = Join-Path $serverDir 'var\admin-initial-password.txt'
Write-Host ""
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Green
Write-Host "   安装完成" -ForegroundColor Green
Write-Host "  ════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "   客户端：双击桌面「日记」" -ForegroundColor White
Write-Host "   管理后台：http://127.0.0.1:$serverPort/admin" -ForegroundColor White
Write-Host "   服务状态：http://127.0.0.1:$serverPort/healthz" -ForegroundColor White
Write-Host ""
if (Test-Path $adminFile) {
  Get-Content $adminFile | Where-Object { $_ -match '用户名|密码' } | ForEach-Object {
    Write-Host "   $_" -ForegroundColor Yellow
  }
} else {
  Write-Host "   管理员账号：admin" -ForegroundColor Yellow
  Write-Host "   （密码见 server\var\admin-initial-password.txt）" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "   想换密码：在 server 目录执行" -ForegroundColor DarkGray
Write-Host "     npm run set-password -- admin 新密码" -ForegroundColor DarkGray
Write-Host ""

$open = if ($env:RJJ_NONINTERACTIVE -eq '1') { 'n' } else { Read-Host "  现在打开管理后台看看？(Y/n)" }
if ($open -ne 'n') { Start-Process "http://127.0.0.1:$serverPort/admin" }
