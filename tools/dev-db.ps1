# 开发数据库：启动一个独立的 PostgreSQL 实例（端口 5544），不碰系统里已有的 5432 实例。
# 用法：  pwsh -File tools/dev-db.ps1 -Action start|stop|status
param(
  [ValidateSet('start', 'stop', 'status')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
$pgBin  = 'C:\Program Files\PostgreSQL\17\bin'
$pgData = 'C:\dev\pg-data'
$pgLog  = 'C:\dev\pg-log.txt'
$port   = 5544

switch ($Action) {
  'start' {
    & "$pgBin\pg_isready.exe" -h 127.0.0.1 -p $port *> $null
    if ($LASTEXITCODE -eq 0) { "开发数据库已在运行 (127.0.0.1:$port)"; break }
    & "$pgBin\pg_ctl.exe" -D $pgData -o "-p $port -c listen_addresses=127.0.0.1" -l $pgLog -w start
    "开发数据库已启动 (127.0.0.1:$port)"
  }
  'stop' {
    & "$pgBin\pg_ctl.exe" -D $pgData -m fast -w stop
    "开发数据库已停止"
  }
  'status' {
    & "$pgBin\pg_isready.exe" -h 127.0.0.1 -p $port
  }
}
