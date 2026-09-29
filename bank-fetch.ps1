# -*- coding: utf-8 -*-
# 银行维护公告抓取：易宝支付 + 快钱 + 央行支付系统维护窗口
# 只保留 banks.json 里列出的（后台启用的）银行，输出 bank-data.json
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = Get-Location }
$cfg = Get-Content (Join-Path $ScriptDir 'banks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$OutFile = Join-Path $ScriptDir 'bank-data.json'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$KeepDays = 3   # 已结束的维护保留几天

# ============ 关键词配置（可自行增删） ============
# 只抓这些：维护 / 即将维护 / 暂时维护 / 银行不可使用
$KeepKw = '维护|維護|暂停|暫停|停机|停機|停止服务|停止服務|不可用|不可使用|无法使用|無法使用|无法交易|系统升级|系統升級'
# 标题命中这些、又不含上面的词 = 其他类公告（限额、费率、结算安排、声明…），直接丢弃
$DropKw = '限额|额度|手续费|费率|结算安排|声明|钓鱼|协议|活动|优惠'

function Get-Page($url) {
  $resp = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent'=$UA; 'Accept-Language'='zh-CN,zh;q=0.9' } -UseBasicParsing -TimeoutSec 25
  return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}
function Strip-Html($h) {
  $t = [regex]::Replace($h, '(?s)<script.*?</script>|<style.*?</style>', '')
  $t = [regex]::Replace($t, '<[^>]+>', ' ')
  $t = $t -replace '&nbsp;', ' ' -replace '&amp;', '&'
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}
# 公告里的时间都是北京时间，转成毫秒时间戳
function To-Ms($y, $mo, $d, $h, $mi) {
  $dto = New-Object DateTimeOffset ([int]$y), ([int]$mo), ([int]$d), ([int]$h), ([int]$mi), 0, ([TimeSpan]::FromHours(8))
  return $dto.ToUnixTimeMilliseconds()
}
# 公告里的银行名 → banks.json 里的银行；匹配不到返回 $null
function Find-Bank($name) {
  $n = $name -replace '\s', ''
  foreach ($g in $cfg.groups) { foreach ($b in $g.banks) { if ($n -match $b.kw) { return [pscustomobject]@{ s = $b.s; g = $g.id } } } }
  return $null
}

$events = New-Object System.Collections.ArrayList
$unmatched = New-Object System.Collections.ArrayList
$sources = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList   # 被过滤掉的非维护公告（只记标题，方便核对）
$aliEvents = New-Object System.Collections.ArrayList  # 支付宝的维护时间段（单独一个分页）
function Add-Event($bankName, $s, $e, $sev, $scope, $title, $url, $src, $pub) {
  if (($bankName -replace '\s', '') -match $cfg.alipay.kw) {
    [void]$aliEvents.Add([pscustomobject]@{ bank = '支付宝'; g = 'alipay'; s = $s; e = $e; sev = $sev; scope = $scope; title = $title; url = $url; src = $src; pub = $pub })
    return
  }
  $b = Find-Bank $bankName
  if (-not $b) { [void]$unmatched.Add("$src：$($bankName -replace '\s','')"); return }
  [void]$events.Add([pscustomobject]@{ bank = $b.s; g = $b.g; s = $s; e = $e; sev = $sev; scope = $scope; title = $title; url = $url; src = $src; pub = $pub })
}

Write-Host ''
Write-Host '  正在抓取 银行 / 支付宝 维护公告 ...' -ForegroundColor Cyan

# ============ 易宝支付：当前生效的公告列表 + 每条详情 ============
$n = 0; $ok = $false
try {
  $list = Get-Page 'https://www.yeepay.com/all-notices'
  $ok = $true
  $seen = @{}
  foreach ($a in [regex]::Matches($list, '(?s)href="/notice-detail/(\d+)"[^>]*>(.*?)</a>')) {
    $id = $a.Groups[1].Value
    if ($seen[$id]) { continue }; $seen[$id] = $true
    $title = (Strip-Html $a.Groups[2].Value)
    # 标题一看就不是维护类的，不用再抓详情
    if (($title -match $DropKw) -and ($title -notmatch $KeepKw)) { [void]$skipped.Add("易宝支付：$title"); continue }
    Start-Sleep -Milliseconds 300
    try {
      $url = "https://www.yeepay.com/notice-detail/$id"
      $txt = Strip-Html (Get-Page $url)
      $body = [regex]::Match($txt, '尊敬的客户(.+?)关于我们 公司介绍').Groups[1].Value
      $wins = [regex]::Matches($body, '(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):\d{2}\s*--\s*(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):\d{2}')
      # 必须同时有「维护类关键词」和「明确的时间段」才算维护公告
      if (($wins.Count -eq 0) -or ("$title $body" -notmatch $KeepKw)) { [void]$skipped.Add("易宝支付：$title"); continue }
      $m = [regex]::Match($txt, '(\d{4}-\d{2}-\d{2})\s+尊敬的客户\s*(.+?)\s*[：:]\s*(.+?)\s*影响时间')
      if (-not $m.Success) { [void]$skipped.Add("易宝支付：$title（格式无法识别）"); continue }
      $pub = $m.Groups[1].Value
      $bankName = $m.Groups[2].Value; $scope = ($m.Groups[3].Value -replace '-保持关注', '').Trim()
      # 只收「不可使用」的；银行还能用、只是可能抖动的不收
      if ($body -notmatch '交易暂停|暂停服务|停止服务|不可用|不可使用|无法使用|无法交易') { [void]$skipped.Add("易宝支付：$title（只是可能抖动，不收）"); continue }
      $sev = 'stop'
      foreach ($w in $wins) {
        $g = $w.Groups
        Add-Event $bankName (To-Ms $g[1].Value $g[2].Value $g[3].Value $g[4].Value $g[5].Value) (To-Ms $g[6].Value $g[7].Value $g[8].Value $g[9].Value $g[10].Value) $sev $scope $title $url '易宝支付' $pub
        $n++
      }
    } catch { Write-Host "    易宝公告 $id 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
} catch { Write-Host "    易宝支付 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '易宝支付'; ok = $ok; count = $n })

# ============ 快钱：「最新银行维护通知」单页 ============
$n = 0; $ok = $false
try {
  $url = 'https://help.99bill.com/index.php/%E5%BF%AB%E9%92%B1%E9%80%9A%E7%9F%A5/%E9%93%B6%E8%A1%8C%E9%A2%9D%E5%BA%A6%E8%B0%83%E6%95%B4%E9%80%9A%E7%9F%A5/2888-10%E6%9C%88%E6%9C%80%E6%96%B0%E9%93%B6%E8%A1%8C%E7%BB%B4%E6%8A%A4%E9%80%9A%E7%9F%A5.html'
  $txt = Strip-Html (Get-Page $url)
  $ok = $true
  $rx = '接\s*(.{2,20}?)\s*通知，银行方将于\s*(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})[:：](\d{2})\s*[-—~至]+\s*(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})[:：](\d{2})\s*进行系统维护，届时我司\s*(.+?)\s*将受到影响'
  foreach ($m in [regex]::Matches($txt, $rx)) {
    $g = $m.Groups
    $bankName = $g[1].Value
    Add-Event $bankName (To-Ms $g[2].Value $g[3].Value $g[4].Value $g[5].Value $g[6].Value) (To-Ms $g[7].Value $g[8].Value $g[9].Value $g[10].Value $g[11].Value) 'stop' ($g[12].Value.Trim()) "$($bankName -replace '\s','')系统维护通知" $url '快钱' ''
    $n++
  }
} catch { Write-Host "    快钱 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '快钱'; ok = $ok; count = $n })

# ============ 支付宝开放平台公告（只留近一年的维护 / 异常类） ============
$aliNotices = New-Object System.Collections.ArrayList
$n = 0; $ok = $false
try {
  $aj = (Get-Page $cfg.alipay.notice_url) | ConvertFrom-Json
  $ok = $true
  $yearAgo = [DateTimeOffset]::UtcNow.AddYears(-1).ToUnixTimeMilliseconds()
  foreach ($a in $aj.announcement) {
    $pubMs = [int64]$a.releaseDate
    if ($pubMs -lt $yearAgo) { continue }
    if (($a.title -notmatch $cfg.alipay.keep) -or ($a.title -match $cfg.alipay.drop)) { [void]$skipped.Add("支付宝：$($a.title)"); continue }
    [void]$aliNotices.Add([pscustomobject]@{ title = [string]$a.title; url = [string]$a.link; pub = $pubMs; src = '支付宝开放平台' })
    $n++
  }
} catch { Write-Host "    支付宝公告 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '支付宝开放平台'; ok = $ok; count = $n })

# ============ 央行支付系统维护窗口（每年公布一次，写在 banks.json） ============
$pboc = New-Object System.Collections.ArrayList
foreach ($w in $cfg.pboc.windows) {
  # 新版 PowerShell 读 JSON 时可能已经把日期转成 datetime，两种都要能处理
  $d = if ($w -is [datetime]) { $w } else { [datetime]::ParseExact([string]$w, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
  [void]$pboc.Add([pscustomobject]@{ s = (To-Ms $d.Year $d.Month $d.Day 0 0); e = (To-Ms $d.Year $d.Month $d.Day 6 0) })
}

# ============ 去重 + 丢掉太久以前的 + 排序 ============
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$cut = $nowMs - $KeepDays * 86400000
$final = @($events | Where-Object { $_.e -ge $cut } | Group-Object { "$($_.bank)|$($_.s)|$($_.e)" } | ForEach-Object { $_.Group[0] } | Sort-Object s)
$pbocFinal = @($pboc | Where-Object { $_.e -ge $cut } | Sort-Object s)

$result = [ordered]@{
  updated   = $nowMs
  sources   = @($sources)
  events    = $final
  pboc      = [ordered]@{ url = $cfg.pboc.url; windows = $pbocFinal }
  alipay    = [ordered]@{
    events  = @($aliEvents | Where-Object { $_.e -ge $cut } | Sort-Object s)
    notices = @($aliNotices | Sort-Object pub -Descending)
  }
  unmatched = @($unmatched | Select-Object -Unique)
  skipped   = @($skipped)
}
$json = $result | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))

foreach ($s in $sources) { Write-Host ("  {0}：{1}，收录 {2} 条" -f $s.name, $(if ($s.ok) { '连接正常' } else { '连接失败' }), $s.count) -ForegroundColor Green }
Write-Host "  完成：启用银行相关 $($final.Count) 个维护时间段；未启用/未识别 $(@($unmatched | Select-Object -Unique).Count) 家" -ForegroundColor Green
Write-Host "  已过滤非维护类公告 $($skipped.Count) 条：" -ForegroundColor DarkGray
foreach ($k in $skipped) { Write-Host "    - $k" -ForegroundColor DarkGray }
