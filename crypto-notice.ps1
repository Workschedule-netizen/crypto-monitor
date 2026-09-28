# -*- coding: utf-8 -*-
# 虚拟币交易所维护/暂停/升级公告检查器
# 抓取 币安(Binance) + 欧易(OKX) 公告，过滤出充提维护相关，生成网页并自动打开
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = Get-Location }
$OutFile = Join-Path $ScriptDir 'index.html'

Write-Host ''
Write-Host '  正在抓取 币安 + Coinbase + 欧易 公告 ...' -ForegroundColor Cyan

# ============ 关键词配置（可自行增删） ============
# 命中这些 = 需要注意（维护 / 暂停 / 升级 / 充提受影响）
$AlertKw  = '暂停|暫停|维护|維護|升級|升级|停机|停止|下架|终止|終止|延迟|延遲|硬分叉|分叉|網絡|网络升级|故障|异常|異常|快照|挖矿|停充|停提|提幣|儲值|钱包|錢包|suspend|suspension|maintenance|halt|upgrade|hard fork|delay|snapshot|migration|integration'
# 命中这些 = 已恢复 / 恢复正常
$ResumeKw = '恢復|恢复|重新开放|重新開放|已完成|已恢复|已恢復|开放充值|開放充值|恢复充值|恢复提|resume|resumption|reopen|resumed|completed|restored'

# 链识别（只保留目标 5 条链）
$ChainMap = [ordered]@{
  'TRON' = 'TRON|TRC20|TRC-20|TRC|波场|波場|Tron'
  'BSC'  = '\bBSC\b|BEP20|BEP-20|BNB Smart|BNB Chain|币安智能链|幣安智能鏈|BNB链|BNB鏈|OpBNB'
  'ETH'  = 'ERC20|ERC-20|以太坊|Ethereum|ETH网络|ETH網絡'
  'TON'  = 'Toncoin|TON网络|TON網絡|TON链|TON鏈|The Open Network|\bTON\b'
  'SOL'  = 'Solana|SOLANA|\bSPL\b|SOL网络|SOL網絡|索拉纳|\bSOL\b'
}

# 严格过滤：只要「涉及5链的充提/维护」或「交易所系统维护」
$StrictKw = '暂停|暫停|维护|維護|停机|停機|停充|停提|充值|儲值|提现|提幣|提币|充提|终止|終止|升级|升級|硬分叉|快照|snapshot|suspend|suspension|maintenance|deposit|withdraw|恢复|恢復|resume|Paused|Delayed|Sends|Receives|halt|hard fork|upgrade'
# 交易所整体维护（不依赖具体链）
$SysKw    = '系统维护|系統維護|系统升级|系統升級|平台维护|平台維護|停机维护|停機維護|系统公告|系統公告|系统故障|系統故障|System Maintenance'
# 明确排除（活动/理财/合约等杂项，命中即丢弃）
$ExcludeKw = '空投|理财|理財|竞赛|競賽|活动|活動|Alpha|HODLer|Launchpool|Megadrop|奖励|獎勵|瓜分|持币|持幣|盘前|盤前|Pre-IPO|合约|合約|风险限额|風險限額|返佣|限时|限時|上线|上線|上市|理财竞技|杠杆|槓桿|保证金|保證金'

function Get-Chains($title) {
  $found = @()
  foreach ($k in $ChainMap.Keys) { if ($title -match $ChainMap[$k]) { $found += $k } }
  return $found
}
function Get-Level($title, $t) {
  # 明确"已恢复/已完成"
  if ($title -match '恢復|恢复|已完成|已恢復|重新开放|重新開放|开放充值|開放充值|resume|resumed|completed|restored') { return 'resume' }
  # "暂停/停机/维护"类（真正需要注意的）
  if ($title -match '暂停|暫停|停止|停机|停機|停充|停提|維護|维护|suspend|suspension|paused|halt|delayed|maintenance') {
    # 超过 3 天前的，视为早已恢复/已过去，不再红色警报
    if ($t -and ($t -lt (Get-Date).AddDays(-3))) { return 'resume' }
    return 'alert'
  }
  # 升级 / 硬分叉（专属标签）
  if ($title -match '升级|升級|硬分叉|hard fork|upgrade') { return 'upgrade' }
  # 其他（支持公告等）= 中性
  return 'info'
}
# 保留条件：涉及5链且是充提/维护语境，或交易所系统维护
function Should-Keep($title) {
  if ($title -match $ExcludeKw) { return $false }
  if ($title -match $SysKw) { return $true }
  if (($title -match $StrictKw) -and ((Get-Chains $title).Count -gt 0)) { return $true }
  return $false
}
# Coinbase 英文标题 → 中文（措辞固定，规则翻译）
function Translate-CB($t) {
  # Sends=提现  Receives=充值
  $t = $t -replace 'Delayed Sends and Receives','充值提现延迟'
  $t = $t -replace 'Delayed Sends/Receives','充值提现延迟'
  $t = $t -replace 'Paused Sends and Receives','暂停充值提现'
  $t = $t -replace 'Paused Sends/Receives','暂停充值提现'
  $t = $t -replace 'Resumed Sends and Receives','恢复充值提现'
  $t = $t -replace 'Resumed Sends/Receives','恢复充值提现'
  $t = $t -replace 'Delayed Receives','充值延迟'
  $t = $t -replace 'Delayed Sends','提现延迟'
  $t = $t -replace 'Paused Receives','暂停充值'
  $t = $t -replace 'Paused Sends','暂停提现'
  $t = $t -replace 'Resumed Receives','恢复充值'
  $t = $t -replace 'Resumed Sends','恢复提现'
  $t = $t -replace 'Scheduled System Maintenance','计划系统维护'
  $t = $t -replace 'Scheduled [Mm]aintenance','计划维护'
  $t = $t -replace 'System Maintenance','系统维护'
  $t = $t -replace 'Under Maintenance','维护中'
  $t = $t -replace '\bMaintenance\b','维护'
  $t = $t -replace '\bNetwork\b','网络'
  $t = $t -replace '\bMigration\b','迁移'
  $t = $t -replace '\bUpgrade\b','升级'
  $t = $t -replace 'Hard Fork','硬分叉'
  $t = $t -replace 'Limit Only','仅限价'
  $t = $t -replace 'Token Changes','代币变更'
  $mon = [ordered]@{ January='1月';February='2月';March='3月';April='4月';May='5月';June='6月';July='7月';August='8月';September='9月';October='10月';November='11月';December='12月' }
  foreach ($k in $mon.Keys) { $t = $t -replace "\b$k\b", $mon[$k] }
  return $t
}
function Esc($s) {
  if ($null -eq $s) { return '' }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

# PS5.1 修复：强制按 UTF-8 解码响应，避免中文乱码
function Get-Json($url, $headers) {
  $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 25
  $bytes = $resp.RawContentStream.ToArray()
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  return ($text | ConvertFrom-Json)
}
# 发送 Telegram 消息（UTF-8 JSON）
function Send-TG($token, $chat, $text) {
  $p = @{ chat_id = $chat; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
  try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($p)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null } catch {}
}
# 检测单条链是否正常，返回 $null=正常，字符串=异常原因
function Test-Chain($type, $url, $maxAgeSec) {
  try {
    if ($type -eq 'tron') {
      $r = Invoke-RestMethod -Uri $url -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 15
      $age = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$r.block_header.raw_data.timestamp) / 1000
      if ($age -le $maxAgeSec) { return $null } else { return "出块停滞约 $([int]$age) 秒" }
    }
    if ($type -eq 'evm') {
      $r = Invoke-RestMethod -Uri $url -Method Post -Body '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' -ContentType 'application/json' -TimeoutSec 15
      $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [Convert]::ToInt64($r.result.timestamp, 16)
      if ($age -le $maxAgeSec) { return $null } else { return "出块停滞约 $([int]$age) 秒" }
    }
    if ($type -eq 'sol') {
      $r = Invoke-RestMethod -Uri $url -Method Post -Body '{"jsonrpc":"2.0","method":"getHealth","id":1}' -ContentType 'application/json' -TimeoutSec 15
      if ($r.result -eq 'ok') { return $null } else { return "节点健康异常" }
    }
    if ($type -eq 'ton') {
      $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
      if ([int64]$r.result.last.seqno -gt 0) { return $null } else { return "无法获取区块" }
    }
    return $null
  } catch { return "连接失败/无响应" }
}

$items = New-Object System.Collections.ArrayList

# ============ 币安 Binance ============
$bnHeaders = @{ 'Accept'='application/json'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'lang'='zh-CN'; 'clienttype'='web' }
# 币安用 catalog/list/query（可返回多条）；48=上币 49=最新消息 161=上新 128/93=其他
# 该接口无 releaseDate，时间取标题内日期，没有则用当天
foreach ($cid in 48,49,157,161,128,93) {
  foreach ($pno in 1,2,3,4) {
    Start-Sleep -Milliseconds 200
    try {
      $r = Get-Json "https://www.binance.com/bapi/composite/v1/public/cms/article/catalog/list/query?catalogId=$cid&pageNo=$pno&pageSize=50" $bnHeaders
      if (-not $r.data.articles -or @($r.data.articles).Count -eq 0) { break }
      foreach ($a in $r.data.articles) {
        if (Should-Keep $a.title) {
          $t = Get-Date
          if ($a.title -match '(\d{4}-\d{2}-\d{2})') { try { $t = [datetime]::ParseExact($matches[1],'yyyy-MM-dd',$null) } catch {} }
          [void]$items.Add([pscustomobject]@{
            Exchange = 'Binance'
            Time     = $t
            Title    = [string]$a.title
            Url      = "https://www.binance.com/zh-CN/support/announcement/$($a.code)"
            Chains   = (Get-Chains $a.title)
            Level    = (Get-Level $a.title $t)
          })
        }
      }
    } catch { Write-Host "    币安分类 $cid 第$pno页 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
}

# ============ 欧易 OKX（充提暂停/恢复专属分类） ============
$okxHeaders = @{ 'Accept'='application/json'; 'Accept-Language'='zh-CN'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
foreach ($pg in 1..5) {
  Start-Sleep -Milliseconds 400
  try {
    $r = Get-Json "https://www.okx.com/api/v5/support/announcements?annType=announcements-deposit-withdrawal-suspension-resumption&page=$pg" $okxHeaders
    if ($r.data.Count -gt 0) {
      foreach ($d in $r.data[0].details) {
        if (-not (Should-Keep $d.title)) { continue }
        $t = try { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.pTime).LocalDateTime } catch { Get-Date }
        [void]$items.Add([pscustomobject]@{
          Exchange = 'OKX'
          Time     = $t
          Title    = [string]$d.title
          Url      = [string]$d.url
          Chains   = (Get-Chains $d.title)
          Level    = (Get-Level $d.title $t)
        })
      }
    }
  } catch { Write-Host "    欧易第 $pg 页抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

# ============ Coinbase（状态页：充提事件 + 计划维护） ============
$cbHeaders = @{ 'Accept'='application/json'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
# 充提暂停/延迟等事件
try {
  $inc = Get-Json "https://status.coinbase.com/api/v2/incidents.json" $cbHeaders
  foreach ($e in $inc.incidents) {
    if (Should-Keep $e.name) {
      $t = try { [datetime]$e.created_at } catch { Get-Date }
      $lv = if ($e.status -match 'resolved|completed|postmortem') { 'resume' } else { 'alert' }
      [void]$items.Add([pscustomobject]@{
        Exchange = 'Coinbase'; Time = $t; Title = (Translate-CB ([string]$e.name)); Url = [string]$e.shortlink
        Chains = (Get-Chains $e.name); Level = $lv
      })
    }
  }
} catch { Write-Host "    Coinbase 事件抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
# 计划维护
try {
  $mnt = Get-Json "https://status.coinbase.com/api/v2/scheduled-maintenances.json" $cbHeaders
  foreach ($e in $mnt.scheduled_maintenances) {
    if (Should-Keep $e.name) {
      $t = try { [datetime]$e.scheduled_for } catch { Get-Date }
      $lv = if ($e.status -match 'completed') { 'resume' } else { 'alert' }
      [void]$items.Add([pscustomobject]@{
        Exchange = 'Coinbase'; Time = $t; Title = (Translate-CB ([string]$e.name)); Url = [string]$e.shortlink
        Chains = (Get-Chains $e.name); Level = $lv
      })
    }
  }
} catch { Write-Host "    Coinbase 维护抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

# ============ OKX 场外 USDT/CNY 快照（买入价 / 卖出价） ============
$okxBuy='—'; $okxSell='—'
try {
  $tms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  # side=sell：商家卖USDT = 你买入USDT的价（取最低=最优）
  $sd=Get-Json "https://www.okx.com/v3/c2c/tradingOrders/books?t=$tms&quoteCurrency=CNY&baseCurrency=USDT&side=sell&paymentMethod=all&userType=all&showTrade=false&showFollow=false&showAlreadyTraded=false&isAbleFilter=false&currentPage=1&numberPerPage=10" $okxHeaders
  $sp=@($sd.data.sell | ForEach-Object { [double]$_.price })
  if ($sp.Count) { $okxBuy = ('{0:0.00}' -f ($sp | Measure-Object -Minimum).Minimum) }
  # side=buy：商家买USDT = 你卖出USDT的价（取最高=最优）
  $bd=Get-Json "https://www.okx.com/v3/c2c/tradingOrders/books?t=$tms&quoteCurrency=CNY&baseCurrency=USDT&side=buy&paymentMethod=all&userType=all&showTrade=false&showFollow=false&showAlreadyTraded=false&isAbleFilter=false&currentPage=1&numberPerPage=10" $okxHeaders
  $bp=@($bd.data.buy | ForEach-Object { [double]$_.price })
  if ($bp.Count) { $okxSell = ('{0:0.00}' -f ($bp | Measure-Object -Maximum).Maximum) }
  Write-Host "  OKX 场外 USDT：买入 $okxBuy / 卖出 $okxSell" -ForegroundColor Green
} catch { Write-Host "    OKX 场外价抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

# ============ 去重 + 只保留近一年 + 排序 ============
$oneYearAgo = (Get-Date).AddYears(-1)
$items = $items | Where-Object { $_.Time -ge $oneYearAgo } | Sort-Object Time -Descending | Group-Object Url | ForEach-Object { $_.Group[0] } | Sort-Object Time -Descending

$today = (Get-Date).Date
$todayAlerts = @($items | Where-Object { $_.Level -eq 'alert' -and $_.Time.Date -eq $today }).Count
$totalCount = @($items).Count
Write-Host "  完成：共 $totalCount 条相关公告，其中今日维护/暂停 $todayAlerts 条" -ForegroundColor Green

# ============ 生成公告行 HTML ============
$levelText = @{ 'alert'='维护/暂停'; 'resume'='已恢复'; 'upgrade'='升级'; 'info'='相关' }
$exClass   = @{ 'Binance'='ex-bn'; 'OKX'='ex-okx'; 'Coinbase'='ex-cb' }
$rowsSb = New-Object System.Text.StringBuilder
if ($totalCount -eq 0) {
  [void]$rowsSb.Append('<div class="empty">当前无维护 / 暂停 / 升级相关公告<br><span>各链充提大概率正常 · 每 5 分钟自动更新</span></div>')
} else {
  foreach ($it in $items) {
    $chainAttr = ($it.Chains -join ' ')
    $chipHtml = ''
    foreach ($c in $it.Chains) { $chipHtml += "<span class='chip'>$c</span>" }
    if (-not $chipHtml) { $chipHtml = "<span class='chip chip-none'>其他/多链</span>" }
    $isToday = if ($it.Time.Date -eq $today) { "<span class='today'>今天</span>" } else { '' }
    $timeStr = $it.Time.ToString('MM-dd HH:mm')
    $lvl = $it.Level
    $ltxt = $levelText[$lvl]
    $exc = $exClass[$it.Exchange]
    $null = $rowsSb.Append(@"
<a class="card lvl-$lvl" href="$(Esc $it.Url)" target="_blank" data-ex="$($it.Exchange)" data-chains="$chainAttr">
  <div class="row1">
    <span class="ex $exc">$($it.Exchange)</span>
    <span class="badge b-$lvl">$ltxt</span>
    $chipHtml
    <span class="time">$isToday $timeStr</span>
  </div>
  <div class="title">$(Esc $it.Title)</div>
</a>
"@)
  }
}
$rows = $rowsSb.ToString()

$updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$bannerClass = if ($todayAlerts -gt 0) { 'has-alert' } else { 'no-alert' }
$bannerText  = if ($todayAlerts -gt 0) { "今日发现 $todayAlerts 条维护 / 暂停公告，请留意相关链的充提" } else { "今日暂无新的维护 / 暂停公告" }

# ============ HTML 模板 ============
$tpl = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>虚拟币监控台</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
  :root{
    --ink:#080b10; --bg:#080b10; --card:#0e141c; --card2:#131b25; --line:#1e2833; --line2:#2a3744;
    --txt:#e9eef4; --sub:#7a8896; --faint:#556270;
    --accent:#3d9bff; --alert:#ea3943; --resume:#16c784; --warn:#f0a020; --info:#556270;
    --bn:#f0b90b; --gold:#f0b90b; --okx:#e9eef4;
    --sans:'Inter','Microsoft YaHei','PingFang SC',system-ui,sans-serif;
    --mono:'JetBrains Mono','Roboto Mono',ui-monospace,monospace;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--ink);background-image:radial-gradient(1100px 380px at 50% -180px,rgba(22,199,132,.06),transparent 70%);color:var(--txt);font-family:var(--sans);line-height:1.5;padding:20px 16px 40px;max-width:1040px;margin:0 auto;-webkit-font-smoothing:antialiased}
  header{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;padding-bottom:16px;margin-bottom:20px;border-bottom:1px solid var(--line)}
  .brand h1{font-size:19px;font-weight:800;letter-spacing:-.02em}
  .brand p{font-size:12px;color:var(--sub);margin-top:3px}
  .head-right{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  #sysStatus{font-family:var(--mono);font-size:12.5px;font-weight:600;padding:6px 12px;border-radius:6px;border:1px solid var(--line2);color:var(--sub);white-space:nowrap}
  #sysStatus.ok{color:var(--resume);border-color:rgba(22,199,132,.4);background:rgba(22,199,132,.07)}
  #sysStatus.bad{color:var(--alert);border-color:rgba(234,57,67,.5);background:rgba(234,57,67,.1)}
  .refresh{background:var(--txt);color:var(--ink);border:none;border-radius:6px;padding:8px 15px;font-size:13px;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block}
  .refresh:hover{opacity:.85}
  .section{margin-bottom:22px}
  .sec-head{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:12px}
  .sec-title{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .sec-title .bar{width:3px;height:16px;border-radius:2px;background:var(--resume);flex:none}
  .sec-title h2{font-size:15px;font-weight:700;letter-spacing:-.01em}
  .sec-title .sub{font-size:12px;color:var(--sub);font-weight:400}
  .sec-meta{font-family:var(--mono);font-size:11.5px;color:var(--sub);display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  .sec-meta b{color:var(--txt);font-weight:600}
  .sec-meta a{color:var(--accent);text-decoration:none}
  .banner{border-radius:8px;padding:11px 15px;font-size:14px;font-weight:600;margin-bottom:16px;display:flex;align-items:center;gap:10px;border:1px solid transparent}
  .banner::before{content:"";width:8px;height:8px;border-radius:50%;flex:none}
  .banner.has-alert{background:rgba(234,57,67,.1);border-color:rgba(234,57,67,.4);color:#ff8a8f}
  .banner.has-alert::before{background:var(--alert);box-shadow:0 0 8px var(--alert)}
  .banner.no-alert{background:rgba(22,199,132,.08);border-color:rgba(22,199,132,.3);color:#5fe0aa}
  .banner.no-alert::before{background:var(--resume);box-shadow:0 0 8px var(--resume)}
  .filters{display:flex;gap:7px;flex-wrap:wrap;margin-bottom:10px;align-items:center}
  .filters button{background:var(--card);color:var(--sub);border:1px solid var(--line);border-radius:7px;padding:6px 13px;font-size:13px;font-weight:500;cursor:pointer;font-family:var(--sans);transition:.12s}
  .filters button:hover{border-color:var(--line2);color:var(--txt)}
  .filters button.active{background:var(--resume);color:#05130d;border-color:var(--resume);font-weight:700}
  .flabel{font-size:12px;color:var(--sub);margin-right:4px;font-weight:600;min-width:66px}
  .filters.exrow button.active{background:var(--gold);color:#1a1200;border-color:var(--gold)}
  .list{display:flex;flex-direction:column;gap:1px;background:var(--line);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  .card{display:block;background:var(--card);border-left:3px solid var(--faint);padding:13px 16px;text-decoration:none;color:inherit;transition:background .12s}
  .card:hover{background:var(--card2)}
  .card.lvl-alert{border-left-color:var(--alert)}
  .card.lvl-resume{border-left-color:var(--resume)}
  .card.lvl-upgrade{border-left-color:#58a6ff}
  .card.lvl-info{border-left-color:var(--faint)}
  .row1{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:7px}
  .ex{font-size:11px;font-weight:700;padding:2px 8px;border-radius:5px}
  .ex-bn{background:var(--gold);color:#1a1200}
  .ex-okx{background:#e9eef4;color:#0e141c}
  .ex-cb{background:#0052ff;color:#fff}
  .badge{font-size:11px;font-weight:600;padding:2px 8px;border-radius:5px}
  .b-alert{background:rgba(234,57,67,.15);color:#ff8a8f}
  .b-resume{background:rgba(22,199,132,.15);color:#5fe0aa}
  .b-upgrade{background:rgba(88,166,255,.15);color:#79b8ff}
  .b-info{background:rgba(122,136,150,.15);color:var(--sub)}
  .chip{font-family:var(--mono);font-size:11px;font-weight:600;padding:2px 7px;border-radius:5px;background:rgba(61,155,255,.12);color:#7cc0ff;border:1px solid rgba(61,155,255,.25)}
  .chip-none{background:rgba(122,136,150,.1);color:var(--sub);border-color:var(--line)}
  .time{margin-left:auto;font-family:var(--mono);font-size:12px;color:var(--sub);white-space:nowrap}
  .today{background:var(--alert);color:#fff;font-size:10px;padding:1px 6px;border-radius:4px;margin-right:5px;font-weight:700}
  .title{font-size:14.5px;color:var(--txt);line-height:1.5}
  .pager{display:flex;gap:6px;justify-content:center;margin-top:16px;flex-wrap:wrap}
  .pager button{font-family:var(--mono);background:var(--card);color:var(--sub);border:1px solid var(--line);border-radius:7px;min-width:36px;height:36px;padding:0 9px;font-size:13px;cursor:pointer;transition:.12s}
  .pager button:hover:not(:disabled){border-color:var(--line2);color:var(--txt)}
  .pager button.active{background:var(--resume);color:#05130d;border-color:var(--resume);font-weight:700}
  .pager button:disabled{opacity:.35;cursor:not-allowed}
  .empty{text-align:center;padding:48px 20px;color:var(--resume);font-size:16px;font-weight:600;background:var(--card)}
  .empty span{display:block;font-size:13px;color:var(--sub);font-weight:400;margin-top:8px}
  footer{margin-top:26px;padding-top:16px;border-top:1px solid var(--line);text-align:center;color:var(--faint);font-size:11.5px;line-height:1.9;font-family:var(--mono)}
  footer a{color:var(--accent);text-decoration:none}
  /* 链实时状态 */
  .chaingrid{display:grid;grid-template-columns:repeat(5,1fr);gap:1px;background:var(--line);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  @media(max-width:680px){.chaingrid{grid-template-columns:repeat(2,1fr)}}
  .chaincard{background:var(--card);padding:14px 13px;position:relative;transition:background .15s}
  .chaincard:hover{background:var(--card2)}
  .chaincard .dot{width:8px;height:8px;border-radius:50%;background:var(--faint);position:absolute;top:14px;right:13px}
  .chaincard.ok .dot{background:var(--resume);box-shadow:0 0 0 3px rgba(22,199,132,.15),0 0 10px var(--resume)}
  .chaincard.warn .dot{background:var(--warn);box-shadow:0 0 0 3px rgba(240,160,32,.15),0 0 10px var(--warn)}
  .chaincard.bad .dot{background:var(--alert);box-shadow:0 0 0 3px rgba(234,57,67,.15),0 0 10px var(--alert);animation:pulse 1s infinite}
  .cc-name{font-size:15px;font-weight:700;letter-spacing:-.01em}
  .cc-name span{display:block;font-family:var(--mono);font-size:10px;color:var(--sub);font-weight:500;margin-top:2px}
  .cc-status{font-size:13px;font-weight:600;margin:10px 0 3px}
  .chaincard.ok .cc-status{color:var(--resume)}
  .chaincard.warn .cc-status{color:var(--warn)}
  .chaincard.bad .cc-status{color:var(--alert)}
  .cc-meta{font-family:var(--mono);font-size:11px;color:var(--sub);word-break:break-all}
  /* 提醒 */
  #livealert{display:none;position:sticky;top:10px;z-index:50;background:var(--alert);color:#fff;font-weight:700;padding:11px 15px;border-radius:8px;margin-bottom:14px;text-align:center;box-shadow:0 4px 24px rgba(234,57,67,.45);animation:pulse 1.2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.6}}
  /* 实时汇率 */
  .usdtwrap{display:grid;grid-template-columns:1fr 1fr;gap:12px}
  @media(max-width:680px){.usdtwrap{grid-template-columns:1fr}}
  .usdtbox{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:15px 16px;position:relative;overflow:hidden}
  .usdtbox.okx::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--gold)}
  .ub-top{font-size:12px;color:var(--sub);margin-bottom:14px;display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:4px}
  .ub-tag{font-family:var(--mono);font-size:10px;color:var(--faint)}
  .ub-prices{display:flex;gap:28px}
  .ub-cell{display:flex;flex-direction:column;gap:5px}
  .ub-cell span{font-size:11px;color:var(--sub)}
  .ub-cell b{font-family:var(--mono);font-size:26px;font-weight:700;letter-spacing:-.02em;line-height:1}
  .ub-cell b.buy{color:var(--alert)}
  .ub-cell b.sell{color:var(--resume)}
  .ub-cell b.live{color:var(--gold)}
  .ub-cell b.rc-chg{font-size:17px}
  .rc-chg{font-family:var(--mono);font-weight:600}
  .rc-chg.up{color:var(--resume)}
  .rc-chg.down{color:var(--alert)}
</style>
</head>
<body>
<header>
  <div class="brand">
    <h1><svg width="26" height="26" viewBox="0 0 24 24" style="vertical-align:-5px;margin-right:9px"><rect x="4" y="8" width="16" height="11" rx="3.5" fill="#3b82f6"/><circle cx="9.5" cy="13" r="1.7" fill="#fff"/><circle cx="14.5" cy="13" r="1.7" fill="#fff"/><path d="M12 4v4" stroke="#3b82f6" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="3.4" r="1.9" fill="#22c55e"/><rect x="9.5" y="16" width="5" height="1.6" rx="0.8" fill="#fff" opacity=".55"/></svg>虚拟币监控台</h1>
    <p>实时链况 · USDT 场外汇率 · 交易所维护公告</p>
  </div>
  <div class="head-right">
    <span id="sysStatus">连接中…</span>
    <a class="refresh" href="#" onclick="location.reload();return false;">刷新页面</a>
  </div>
</header>
<div id="livealert"></div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar"></span><h2>链路实时状态</h2><span class="sub">直读区块链节点 · 15s 自动刷新</span></div>
    <span class="sec-meta">更新 <b id="upd">—</b> · 下次 <b id="cd">15</b>s · <a href="#" id="reload">刷新</a></span>
  </div>
  <div class="chaingrid" id="chaingrid"></div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--gold)"></span><h2>USDT 汇率</h2><span class="sub">OKX 场外 vs 市场实时（对比你系统 6.9）</span></div>
    <span class="sec-meta">市场价 <b id="rateupd">—</b></span>
  </div>
  <div class="usdtwrap">
    <div class="usdtbox okx">
      <div class="ub-top">OKX 场外 · USDT / CNY<span class="ub-tag">快照 __UPDATED__</span></div>
      <div class="ub-prices">
        <div class="ub-cell"><span>购买（你买入）</span><b class="buy">¥__OKXBUY__</b></div>
        <div class="ub-cell"><span>出售（你卖出）</span><b class="sell">¥__OKXSELL__</b></div>
      </div>
    </div>
    <div class="usdtbox">
      <div class="ub-top">市场实时 · USDT / CNY<span class="ub-tag">60s · CoinGecko</span></div>
      <div class="ub-prices">
        <div class="ub-cell"><span>当前价</span><b class="live" id="mktcny">—</b></div>
        <div class="ub-cell"><span>24h</span><b id="mktchg" class="rc-chg">—</b></div>
      </div>
    </div>
  </div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--alert)"></span><h2>交易所维护 / 暂停公告</h2><span class="sub">仅 5 链 + 系统维护</span></div>
  </div>
  <div class="banner __BANNERCLASS__">__BANNERTEXT__</div>
  <div class="filters exrow" id="exFilters">
    <span class="flabel">按交易所</span>
    <button class="active" data-e="all">全部</button>
    <button data-e="Binance">币安</button>
    <button data-e="OKX">欧易</button>
    <button data-e="Coinbase">Coinbase</button>
  </div>
  <div class="filters" id="chainFilters">
    <span class="flabel">按链</span>
    <button class="active" data-c="all">全部</button>
    <button data-c="TRON">TRON</button>
    <button data-c="BSC">BSC</button>
    <button data-c="ETH">ETH</button>
    <button data-c="TON">TON</button>
    <button data-c="SOL">SOL</button>
  </div>
  <div class="list" id="list">
__ROWS__
  </div>
  <div class="pager" id="pager"></div>
</div>
<footer>
  公告更新时间：__UPDATED__（UTC）｜ 来源：Binance / OKX / Coinbase 官方接口 · 每 5 分钟由 GitHub 自动更新<br>
  链实时状态 &amp; 汇率：网页内每 15~60 秒自动刷新（TronGrid / PublicNode / Toncenter / CoinGecko）<br>
  仅显示近一年内、涉及 TRON/BSC/ETH/TON/SOL 或交易所系统维护的公告 ｜ 点卡片可跳转官方原文
</footer>
<script>
  var chainF='all', exF='all', PAGE_SIZE=10, curPage=1, filtered=[];
  var cards=document.querySelectorAll('#list .card');
  function computeFiltered(){
    filtered=[];
    cards.forEach(function(c){
      var okChain=(chainF==='all')||((' '+c.getAttribute('data-chains')+' ').indexOf(' '+chainF+' ')>=0);
      var okEx=(exF==='all')||(c.getAttribute('data-ex')===exF);
      if(okChain&&okEx) filtered.push(c);
    });
  }
  function renderPager(pages){
    var pg=document.getElementById('pager'); pg.innerHTML='';
    if(pages<=1) return;
    function mk(txt,page,active,disabled){
      var b=document.createElement('button'); b.textContent=txt;
      if(active) b.className='active';
      if(disabled){ b.disabled=true; }
      else b.addEventListener('click',function(){ renderPage(page); var el=document.getElementById('exFilters'); if(el)el.scrollIntoView({behavior:'smooth',block:'start'}); });
      pg.appendChild(b);
    }
    mk('‹',curPage-1,false,curPage<=1);
    for(var i=1;i<=pages;i++){ mk(String(i),i,i===curPage,false); }
    mk('›',curPage+1,false,curPage>=pages);
  }
  function renderPage(p){
    var pages=Math.ceil(filtered.length/PAGE_SIZE)||1;
    if(p<1)p=1; if(p>pages)p=pages; curPage=p;
    cards.forEach(function(c){ c.style.display='none'; });
    filtered.slice((p-1)*PAGE_SIZE, p*PAGE_SIZE).forEach(function(c){ c.style.display='block'; });
    renderPager(pages);
  }
  function applyFilter(){ computeFiltered(); renderPage(1); }
  document.querySelectorAll('#chainFilters button').forEach(function(b){
    b.addEventListener('click',function(){
      document.querySelectorAll('#chainFilters button').forEach(function(x){x.classList.remove('active')});
      b.classList.add('active'); chainF=b.getAttribute('data-c'); applyFilter();
    });
  });
  document.querySelectorAll('#exFilters button').forEach(function(b){
    b.addEventListener('click',function(){
      document.querySelectorAll('#exFilters button').forEach(function(x){x.classList.remove('active')});
      b.classList.add('active'); exF=b.getAttribute('data-e'); applyFilter();
    });
  });
  applyFilter();
  // ====== 链实时状态：浏览器直接读区块链节点，每 15 秒自动更新 ======
  var CHAINS=[
    {k:'TRON',n:'TRON',s:'TRC20',t:'tron',u:'https://api.trongrid.io/wallet/getnowblock',bt:3},
    {k:'BSC', n:'BSC', s:'BEP20',t:'evm', u:'https://bsc-rpc.publicnode.com',bt:3},
    {k:'ETH', n:'Ethereum',s:'ERC20',t:'evm',u:'https://ethereum-rpc.publicnode.com',bt:12},
    {k:'SOL', n:'Solana',s:'SPL', t:'sol', u:'https://solana-rpc.publicnode.com',bt:1},
    {k:'TON', n:'TON', s:'TON',  t:'ton', u:'https://toncenter.com/api/v2/getMasterchainInfo',bt:5}
  ];
  var last={};
  function jrpc(u,m,p){return fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',method:m,params:p||[],id:1})}).then(function(r){return r.json();});}
  function fetchChain(c){
    if(c.t==='tron'){return fetch(c.u,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(function(r){return r.json();}).then(function(j){return {h:j.block_header.raw_data.number,ts:j.block_header.raw_data.timestamp};});}
    if(c.t==='evm'){return jrpc(c.u,'eth_getBlockByNumber',['latest',false]).then(function(j){return {h:parseInt(j.result.number,16),ts:parseInt(j.result.timestamp,16)*1000};});}
    if(c.t==='sol'){return Promise.all([jrpc(c.u,'getHealth'),jrpc(c.u,'getSlot')]).then(function(a){var health=a[0].result||(a[0].error&&a[0].error.message)||'?';return {h:a[1].result,health:health};});}
    if(c.t==='ton'){return fetch(c.u).then(function(r){return r.json();}).then(function(j){return {h:j.result.last.seqno};});}
  }
  function judge(c,d){
    var now=Date.now();
    if(d.ts){
      var age=Math.round((now-d.ts)/1000);
      var meta='区块 '+d.h+' ｜ '+age+'s 前出块';
      if(age<=Math.max(c.bt*8,45)) return {cls:'ok',status:'正常运行',meta:meta};
      if(age<=c.bt*30) return {cls:'warn',status:'出块变慢',meta:meta};
      return {cls:'bad',status:'疑似停摆/维护',meta:meta};
    }
    if(c.t==='sol'){
      var m1='slot '+d.h;
      if(d.health==='ok') return {cls:'ok',status:'正常运行',meta:m1};
      return {cls:'warn',status:'节点落后',meta:m1+' ｜ '+d.health};
    }
    if(c.t==='ton'){
      var m2='seqno '+d.h;
      if(last[c.k]==null) return {cls:'ok',status:'已连接',meta:m2};
      if(d.h>last[c.k]) return {cls:'ok',status:'正常运行',meta:m2};
      return {cls:'bad',status:'区块未推进',meta:m2};
    }
  }
  function renderCard(c,res){
    var el=document.getElementById('cc-'+c.k); if(!el)return;
    el.className='chaincard '+res.cls;
    el.querySelector('.cc-status').textContent=res.status;
    el.querySelector('.cc-meta').textContent=res.meta;
  }
  // ====== 异常视觉提醒：横幅 + 状态 + 标题闪烁 ======
  var prevCls={}, flashTimer=null;
  function flashTitle(msg){ if(flashTimer)return; var on=false; flashTimer=setInterval(function(){document.title=on?'虚拟币监控台':('🔴 '+msg);on=!on;},800); }
  function stopFlash(){ if(flashTimer){clearInterval(flashTimer);flashTimer=null;document.title='虚拟币监控台';} }
  function handleAlerts(newlyBad,badNow){
    var lb=document.getElementById('livealert');
    var ss=document.getElementById('sysStatus');
    if(badNow.length>0){
      lb.style.display='block';
      lb.textContent='● 异常链：'+badNow.join('、')+' — 请立即核实充提状态！';
      if(ss){ ss.textContent='▲ '+badNow.length+' 链异常'; ss.className='bad'; }
      flashTitle(badNow.join('/')+' 异常');
    } else {
      lb.style.display='none'; stopFlash();
      if(ss){ ss.textContent='● 链路全部正常'; ss.className='ok'; }
    }
  }
  function updateAll(){
    Promise.all(CHAINS.map(function(c){
      return fetchChain(c).then(function(d){var res=judge(c,d);last[c.k]=d.h;return {c:c,res:res};})
      .catch(function(e){return {c:c,res:{cls:'bad',status:'读取失败',meta:'节点无响应'}};});
    })).then(function(arr){
      var newlyBad=[],badNow=[];
      arr.forEach(function(x){
        renderCard(x.c,x.res);
        if(x.res.cls==='bad'){ badNow.push(x.c.n); if(prevCls[x.c.k]!=='bad')newlyBad.push(x.c.n); }
        prevCls[x.c.k]=x.res.cls;
      });
      handleAlerts(newlyBad,badNow);
      var u=document.getElementById('upd'); if(u)u.textContent=new Date().toLocaleTimeString();
    });
  }
  (function(){
    var g=document.getElementById('chaingrid');
    CHAINS.forEach(function(c){
      var d=document.createElement('div');d.className='chaincard';d.id='cc-'+c.k;
      d.innerHTML='<div class="dot"></div><div class="cc-name">'+c.n+'<span>'+c.s+'</span></div><div class="cc-status">检测中…</div><div class="cc-meta">—</div>';
      g.appendChild(d);
    });
  })();
  var INT=15,cd=INT;
  updateAll();
  setInterval(function(){cd--;if(cd<=0){cd=INT;updateAll();}var e=document.getElementById('cd');if(e)e.textContent=cd;},1000);
  document.getElementById('reload').addEventListener('click',function(ev){ev.preventDefault();cd=INT;updateAll();});
  // ====== USDT 市场实时价：CoinGecko，浏览器直连，每 60 秒更新 ======
  function updateRates(){
    fetch('https://api.coingecko.com/api/v3/simple/price?ids=tether&vs_currencies=cny&include_24hr_change=true')
    .then(function(r){return r.json();}).then(function(d){
      var x=d.tether; if(!x)return;
      var e=document.getElementById('mktcny'); if(e)e.textContent='¥'+x.cny.toFixed(2);
      var chg=x.cny_24h_change||0; var ce=document.getElementById('mktchg');
      if(ce){ ce.textContent=(chg>=0?'↑ +':'↓ ')+chg.toFixed(2)+'%'; ce.className='rc-chg '+(chg>=0?'up':'down'); }
      var u=document.getElementById('rateupd'); if(u)u.textContent=new Date().toLocaleTimeString();
    }).catch(function(e){ var u=document.getElementById('rateupd'); if(u)u.textContent='读取失败(稍后重试)'; });
  }
  updateRates();
  setInterval(updateRates,60000);
  // 公告数据每 5 分钟随页面自动刷新（重新载入 GitHub 最新生成的 index.html）
  setTimeout(function(){ location.reload(); }, 300000);
</script>
</body>
</html>
'@

$html = $tpl.Replace('__BANNERCLASS__', $bannerClass).Replace('__BANNERTEXT__', $bannerText).Replace('__ROWS__', $rows).Replace('__OKXBUY__', $okxBuy).Replace('__OKXSELL__', $okxSell).Replace('__UPDATED__', $updated)
# 「重新抓取」链接指向本脚本的 bat 启动器

# 用 UTF-8 写出（PS5.1 的 utf8 带 BOM，配合 meta charset 无乱码）
$html | Out-File -FilePath $OutFile -Encoding utf8

Write-Host "  网页已生成：$OutFile" -ForegroundColor Green

# ============ Telegram 推送（配置了 Secrets 时；只推近3天内、未推过的 维护/暂停/升级）============
$tgToken = $env:TG_TOKEN; $tgChat = $env:TG_CHAT
if ($tgToken -and $tgChat) {
  $pushedFile = Join-Path $ScriptDir 'pushed.txt'
  $pushed = @(); if (Test-Path $pushedFile) { $pushed = @(Get-Content $pushedFile -Encoding UTF8) }
  $recent = (Get-Date).AddDays(-3)
  $toNotify = @($items | Where-Object { ($_.Level -eq 'alert' -or $_.Level -eq 'upgrade') -and $_.Time -ge $recent })
  $newCount = 0
  foreach ($n in $toNotify) {
    if ($pushed -contains $n.Url) { continue }
    $emoji = if ($n.Level -eq 'alert') { "🔴" } else { "🔵" }
    $chains = if ($n.Chains) { ($n.Chains -join '/') } else { '多链' }
    $msg = "$emoji $($levelText[$n.Level]) · $($n.Exchange)`n链：$chains`n$($n.Title)`n$($n.Url)"
    $payload = @{ chat_id = $tgChat; text = $msg; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
      Invoke-RestMethod -Uri "https://api.telegram.org/bot$tgToken/sendMessage" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
      $pushed += $n.Url; $newCount++; Start-Sleep -Milliseconds 400
    } catch { Write-Host "  Telegram 推送失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  @($pushed | Select-Object -Last 500) | Out-File -FilePath $pushedFile -Encoding UTF8
  Write-Host "  Telegram：本次新推送 $newCount 条" -ForegroundColor Cyan

  # ---- 链本身异常检测 + 推送（含恢复通知，自动去重）----
  $chainLogFile = Join-Path $ScriptDir 'chainlog.txt'
  $prevBad = @(); if (Test-Path $chainLogFile) { $prevBad = @(Get-Content $chainLogFile -Encoding UTF8 | Where-Object { $_ }) }
  $chainDefs = @(
    @{ n='TRON'; t='tron'; u='https://api.trongrid.io/wallet/getnowblock'; age=180 },
    @{ n='BSC';  t='evm';  u='https://bsc-rpc.publicnode.com'; age=120 },
    @{ n='ETH';  t='evm';  u='https://ethereum-rpc.publicnode.com'; age=300 },
    @{ n='SOL';  t='sol';  u='https://solana-rpc.publicnode.com'; age=0 },
    @{ n='TON';  t='ton';  u='https://toncenter.com/api/v2/getMasterchainInfo'; age=0 }
  )
  $nowBad = @()
  foreach ($ch in $chainDefs) {
    $reason = Test-Chain $ch.t $ch.u $ch.age
    if ($reason) {
      $nowBad += $ch.n
      if ($prevBad -notcontains $ch.n) { Send-TG $tgToken $tgChat "🔴 链异常 · $($ch.n)`n$reason`n请留意该链充提是否受影响。" }
    } elseif ($prevBad -contains $ch.n) {
      Send-TG $tgToken $tgChat "🟢 链已恢复 · $($ch.n)`n出块恢复正常。"
    }
  }
  @($nowBad) | Out-File -FilePath $chainLogFile -Encoding UTF8
  Write-Host "  链检测：当前异常 $($nowBad.Count) 条" -ForegroundColor Cyan

  # ---- 每日定时排查报告（北京时间 12:00 与 00:00 各一次）----
  $bjNow = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
  $slot = $null
  if ($bjNow.Hour -eq 12) { $slot = $bjNow.ToString('yyyy-MM-dd') + '-noon' }
  elseif ($bjNow.Hour -eq 0) { $slot = $bjNow.ToString('yyyy-MM-dd') + '-midnight' }
  if ($slot) {
    $reportFile = Join-Path $ScriptDir 'lastreport.txt'
    $lastSlot = ''; if (Test-Path $reportFile) { $lastSlot = ((Get-Content $reportFile -Encoding UTF8 -Raw)).Trim() }
    if ($slot -ne $lastSlot) {
      $chainLine = if ($nowBad.Count -eq 0) { '五条链全部正常 ✅' } else { '⚠ 异常：' + ($nowBad -join '、') }
      $report = "📊 虚拟币监控 · 每日排查`n$($bjNow.ToString('MM-dd HH:mm')) 北京`n———————`n链状态：$chainLine`nUSDT场外：买 ¥$okxBuy / 卖 ¥$okxSell`n近3天维护/暂停/升级：$($toNotify.Count) 条`n———————`nhttps://workschedule-netizen.github.io/crypto-monitor/"
      Send-TG $tgToken $tgChat $report
      $slot | Out-File -FilePath $reportFile -Encoding UTF8
      Write-Host "  已发送每日排查报告（$slot）" -ForegroundColor Cyan
    }
  }
}

# 手动触发（workflow_dispatch）时发一条测试消息，确认推送通道
if ($tgToken -and $tgChat -and $env:GITHUB_EVENT_NAME -eq 'workflow_dispatch') {
  $tmsg = "✅ 虚拟币监控台 · 推送测试成功`n通道正常，当前共 $totalCount 条相关公告。`n真出现维护/暂停/升级时会自动通知你。"
  $tp = @{ chat_id = $tgChat; text = $tmsg; disable_web_page_preview = $true } | ConvertTo-Json -Compress
  try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$tgToken/sendMessage" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($tp)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null; Write-Host "  已发送手动测试消息" -ForegroundColor Cyan } catch {}
}

Write-Host '  正在打开浏览器 ...' -ForegroundColor Cyan
if (-not $env:GITHUB_ACTIONS) { try { Start-Process $OutFile } catch {} }






























