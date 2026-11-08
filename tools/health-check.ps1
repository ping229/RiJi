# RiJi 交付前体检
#
# 逐项检查服务端与数据库的关键能力，输出 PASS/FAIL 明细。
# 用法：pwsh -File tools/health-check.ps1 [-Base http://127.0.0.1:8080]
#
# 说明：本脚本只做只读检查与少量可清理的写操作（会删掉自己创建的临时用户），
# 不会动你已有的日记数据。

param(
  [string]$Base = 'http://127.0.0.1:8080',
  [string]$AdminUser = 'admin',
  # 不再把口令写死在脚本里：从环境变量或 server/var 的初始密码文件读
  [string]$AdminPass = $(if ($env:RJJ_ADMIN_PASSWORD) { $env:RJJ_ADMIN_PASSWORD } else { '' }),
  [int]$PgPort = 5544,
  [string]$PgUser = 'diary',
  [string]$PgDb = 'riji'
)

# 没给口令时，尝试读本机首次启动生成的文件（只有本机能读，不会进版本库）
if (-not $AdminPass) {
  $initial = Join-Path $PSScriptRoot '..\server\var\admin-initial-password.txt'
  if (Test-Path $initial) {
    $line = Get-Content $initial -Encoding UTF8 | Where-Object { $_ -like '密码：*' } | Select-Object -First 1
    if ($line) { $AdminPass = ($line -split '：', 2)[1].Trim() }
  }
}

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$results = @()
$script:token = $null

function Skip($name, $reason) {
  $script:results += [pscustomobject]@{ 检查项 = $name; 结果 = 'SKIP'; 说明 = $reason }
  Write-Host ("  [SKIP] {0} — {1}" -f $name, $reason) -ForegroundColor Yellow
}

function Check($name, [scriptblock]$body) {
  try {
    $detail = & $body
    $script:results += [pscustomobject]@{ 检查项 = $name; 结果 = 'PASS'; 说明 = "$detail" }
    Write-Host ("  [PASS] {0} — {1}" -f $name, $detail) -ForegroundColor Green
  } catch {
    $msg = $_.Exception.Message
    if ($msg -like '__SKIP__*') {
      $script:results += [pscustomobject]@{ 检查项 = $name; 结果 = 'SKIP'; 说明 = $msg.Substring(8) }
      Write-Host ("  [SKIP] {0} — {1}" -f $name, $msg.Substring(8)) -ForegroundColor Yellow
      return
    }
    if ($_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
    $script:results += [pscustomobject]@{ 检查项 = $name; 结果 = 'FAIL'; 说明 = "$msg" }
    Write-Host ("  [FAIL] {0} — {1}" -f $name, $msg) -ForegroundColor Red
  }
}

function Api($method, $path, $body = $null) {
  $headers = @{}
  if ($script:token) { $headers['Authorization'] = "Bearer $($script:token)" }
  $params = @{
    Uri = "$Base$path"
    Method = $method
    Headers = $headers
    TimeoutSec = 15
    SkipHttpErrorCheck = $true
  }
  if ($body -ne $null) {
    $params['ContentType'] = 'application/json'
    $params['Body'] = ($body | ConvertTo-Json -Depth 10 -Compress)
  }
  $res = Invoke-WebRequest @params
  $json = $null
  try { $json = $res.Content | ConvertFrom-Json } catch { }
  return [pscustomobject]@{ Status = [int]$res.StatusCode; Raw = $res.Content; Json = $json }
}

Write-Host "`n=== RiJi 体检开始：$Base ===`n" -ForegroundColor Cyan

Check 'PostgreSQL 在监听' {
  $c = Get-NetTCPConnection -LocalPort $PgPort -State Listen -ErrorAction SilentlyContinue
  if (-not $c) { throw "端口 $PgPort 未监听" }
  "端口 $PgPort 正常"
}

Check '服务端 /healthz 正常' {
  $r = Api 'GET' '/healthz'
  if ($r.Status -ne 200) { throw "HTTP $($r.Status)" }
  "节点 $($r.Json.nodeId) / 角色 $($r.Json.role)"
}

Check '管理后台可访问' {
  $r = Api 'GET' '/admin'
  if ($r.Status -ne 200) { throw "HTTP $($r.Status)" }
  if ($r.Raw -notmatch '管理') { throw '页面内容不符合预期' }
  '返回了管理界面'
}

Check '管理员登录' {
  if (-not $AdminPass) {
    throw '__SKIP__没有提供管理员口令：设置环境变量 RJJ_ADMIN_PASSWORD，或用 -AdminPass 传入'
  }
  $r = Api 'POST' '/api/auth/login' @{ username = $AdminUser; password = $AdminPass; device = @{ name = '体检脚本'; platform = 'windows' } }
  if ($r.Status -ne 200) { throw "HTTP $($r.Status)：$($r.Raw)" }
  $script:token = $r.Json.accessToken
  "账号 $($r.Json.user.username)"
}

Check '可写窗口是 8 天且今天在末尾' {
  $r = Api 'GET' '/api/calendar'
  if ($r.Status -ne 200) { throw "HTTP $($r.Status)" }
  $dates = @($r.Json.writableDates)
  if ($dates.Count -ne 8) { throw "可写窗口为 $($dates.Count) 天，应为 8" }
  if ($dates[-1] -ne $r.Json.today) { throw "最后一天不是今天：$($dates[-1]) vs $($r.Json.today)" }
  "窗口 $($dates[0]) ~ $($dates[-1])"
}

$script:writtenBlockId = $null

Check '写入今天的日记并读回' {
  $cal = (Api 'GET' '/api/calendar').Json
  $login = (Api 'POST' '/api/auth/login' @{ username = $AdminUser; password = $AdminPass; device = @{ name = '体检写入'; platform = 'windows' } }).Json
  $dev = $login.deviceId
  if (-not $dev) { throw '登录没有返回设备 ID' }
  $phys = '{0:x12}' -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $blockId = [guid]::NewGuid().ToString()
  if (-not $dev) { throw '缺少设备 ID' }; $vv = @{}; $vv[$dev] = 1
  $text = '体检写入 ' + (Get-Date -Format 'HH:mm:ss')
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ text = $text } | ConvertTo-Json -Compress)))
  $ops = @(@{ blockId = $blockId; blockType = 'text'; orderKey = '999000'; vv = $vv; hlc = "$phys-0000-$dev"; payload = $payload; enc = 'none' })
  $w = Api 'POST' "/api/diaries/$($cal.today)/batch" @{ tzId = $cal.tzId; clientNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); deviceId = $dev; operations = $ops }
  if ($w.Status -ne 200) { throw "写入失败 HTTP $($w.Status)：$($w.Raw)" }
  $script:writtenBlockId = $blockId
  $d = Api 'GET' "/api/diaries/$($cal.today)"
  $hit = @($d.Json.blocks) | Where-Object { $_.blockId -eq $blockId }
  if (-not $hit) { throw '写入成功但读不回来' }
  '写入并读回成功'
}

Check '时间窗口外（8 天前）拒绝写入' {
  $cal = (Api 'GET' '/api/calendar').Json
  $old = ([datetime]$cal.today).AddDays(-8).ToString('yyyy-MM-dd')
  $login = (Api 'POST' '/api/auth/login' @{ username = $AdminUser; password = $AdminPass; device = @{ name = '体检窗口'; platform = 'windows' } }).Json
  $dev = $login.deviceId
  if (-not $dev) { throw '登录没有返回设备 ID' }
  if (-not $dev) { throw '缺少设备 ID' }; $vv = @{}; $vv[$dev] = 1
  $ops = @(@{ blockId = [guid]::NewGuid().ToString(); blockType = 'text'; orderKey = '999001'; vv = $vv; hlc = '0000018c00000000-0000-x'; payload = 'e30='; enc = 'none' })
  $r = Api 'POST' "/api/diaries/$old/batch" @{ tzId = $cal.tzId; clientNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); deviceId = $dev; operations = $ops }
  if ($r.Status -ge 200 -and $r.Status -lt 300) { throw "不该允许写入 $old（HTTP $($r.Status)）" }
  "拒绝写入 $old（HTTP $($r.Status)）"
}

Check '未来日期拒绝写入' {
  $cal = (Api 'GET' '/api/calendar').Json
  $future = ([datetime]$cal.today).AddDays(1).ToString('yyyy-MM-dd')
  $r = Api 'POST' "/api/diaries/$future/batch" @{ tzId = $cal.tzId; clientNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); deviceId = 'x'; operations = @() }
  if ($r.Status -ge 200 -and $r.Status -lt 300) { throw "不该允许写入未来日期（HTTP $($r.Status)）" }
  "拒绝写入 $future（HTTP $($r.Status)）"
}

Check '媒体上传与下载往返' {
  $key = [guid]::NewGuid().ToString('N')
  $bytes = [byte[]]::new(1024)
  (New-Object Random).NextBytes($bytes)
  $headers = @{ Authorization = "Bearer $($script:token)"; 'x-media-key' = $key; 'x-media-mime' = 'image/png' }
  $up = Invoke-WebRequest -Uri "$Base/api/media" -Method Post -Headers $headers -ContentType 'application/octet-stream' -Body $bytes -SkipHttpErrorCheck -TimeoutSec 20
  if ([int]$up.StatusCode -ne 200) { throw "上传 HTTP $($up.StatusCode)" }
  $down = Invoke-WebRequest -Uri "$Base/api/media/$key" -Method Get -Headers @{ Authorization = "Bearer $($script:token)" } -SkipHttpErrorCheck -TimeoutSec 20
  if ([int]$down.StatusCode -ne 200) { throw "下载 HTTP $($down.StatusCode)" }
  if ($down.RawContentLength -ne 1024) { throw "下载大小 $($down.RawContentLength)（应为 1024）" }
  '上传 1024 字节，下载一致'
}

Check '普通用户访问管理接口被拒' {
  $uname = 'check-' + (Get-Random -Maximum 99999)
  $create = Api 'POST' '/api/admin/users' @{ username = $uname; password = 'temp-pass-2026'; role = 'user' }
  if ($create.Status -ne 200 -and $create.Status -ne 201) { throw "创建临时用户失败 HTTP $($create.Status)" }
  $userLogin = Api 'POST' '/api/auth/login' @{ username = $uname; password = 'temp-pass-2026' }
  if ($userLogin.Status -ne 200) { throw "临时用户登录失败 HTTP $($userLogin.Status)" }
  $userToken = $userLogin.Json.accessToken
  $denied = Invoke-WebRequest -Uri "$Base/api/admin/users" -Method Get -Headers @{ Authorization = "Bearer $userToken" } -SkipHttpErrorCheck -TimeoutSec 15
  # 清理临时用户
  $uid = $userLogin.Json.user.id
  Invoke-WebRequest -Uri "$Base/api/admin/users/$uid" -Method Delete -Headers @{ Authorization = "Bearer $($script:token)" } -ContentType 'application/json' -Body (@{ confirmUsername = $uname } | ConvertTo-Json) -SkipHttpErrorCheck -TimeoutSec 15 | Out-Null
  if ([int]$denied.StatusCode -ne 403) { throw "普通用户返回 $($denied.StatusCode)，应为 403" }
  '普通用户得到 403，临时账号已清理'
}

Check '数据库里存在密文块（端到端加密生效）' {
  $psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
  if (-not (Test-Path $psql)) { throw '找不到 psql，跳过' }
  $n = & $psql -h 127.0.0.1 -p $PgPort -U $PgUser -d $PgDb -tAc "select count(*) from blocks where enc = 'aes-256-gcm';" 2>&1
  $count = [int]("$n".Trim())
  if ($count -le 0) { throw '没有找到加密块，加密链路可能未启用' }
  "$count 个加密块"
}

Check '多节点：副本数据与主节点一致' {
  $replica = Get-NetTCPConnection -LocalPort 8081 -State Listen -ErrorAction SilentlyContinue
  if (-not $replica) { throw '__SKIP__副本未运行（多节点为可选项，单机使用不受影响）' }
  $psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
  $main = [int](& $psql -h 127.0.0.1 -p $PgPort -U $PgUser -d $PgDb -tAc 'select count(*) from blocks;' 2>&1).Trim()
  # 复制是异步的：刚写入的块可能要几秒才到副本，这里轮询等待而不是一次定生死
  $rep = 0
  for ($i = 0; $i -lt 10; $i += 1) {
    $rep = [int](& $psql -h 127.0.0.1 -p $PgPort -U $PgUser -d riji_replica -tAc 'select count(*) from blocks;' 2>&1).Trim()
    if ($rep -eq $main) { break }
    Start-Sleep -Seconds 2
  }
  if ($main -ne $rep) { throw "等待 20 秒后仍不一致：主 $main 块 / 副本 $rep 块" }
  "两边都是 $main 块"
}

# ---------------------------------------------------------------- 汇总
$pass = @($results | Where-Object { $_.结果 -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.结果 -eq 'FAIL' }).Count
$skip = @($results | Where-Object { $_.结果 -eq 'SKIP' }).Count
Write-Host "`n=== 汇总：$pass 项通过 / $fail 项失败 / $skip 项跳过 ===`n" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$md = @"
# 交付前体检报告

生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
检查地址：$Base
结果：**$pass 项通过 / $fail 项失败 / $skip 项跳过**

| 检查项 | 结果 | 说明 |
|---|---|---|
"@
foreach ($r in $results) {
  $md += "| $($r.检查项) | $($r.结果) | $($r.说明) |`n"
}
$md = $md.Replace('|---|---|---||', "|---|---|---|`n|")
$mdPath = Join-Path $PSScriptRoot '..\docs\验收体检结果.md'
[IO.File]::WriteAllText($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "报告已写入：$mdPath`n" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 } else { exit 0 }
