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

function Get-Page($url, $timeout = 25) {
  $resp = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent'=$UA; 'Accept-Language'='zh-CN,zh;q=0.9' } -UseBasicParsing -TimeoutSec $timeout
  return [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}
# 银行官网从海外连偶尔会超时：失败再试一次
function Get-PageRetry($url) {
  try { return (Get-Page $url 15) }
  catch {
    # 对方服务器太旧、握手被拒绝的，重试也没用，直接改用下面的放宽方式
    if ($IsLinux -and ((Ex-Chain $_.Exception) -match 'legacy renegotiation')) { return (Get-PageLegacyTls $url) }
    Start-Sleep -Seconds 2; return (Get-Page $url 15)
  }
}
# 有些银行官网（例如建设银行）的服务器比较旧，不支持「安全重新协商」。
# GitHub 的服务器是 Linux，上面的 OpenSSL 3 默认拒绝跟这种服务器握手（unsafe legacy renegotiation disabled），Windows 上没这个问题。
# 只对出这个错的网址放宽：另外起一个 curl，带一份只打开这个选项的 OpenSSL 设定。其他网站和 Telegram 的连线不受影响
function Get-PageLegacyTls($url) {
  $conf = Join-Path ([System.IO.Path]::GetTempPath()) 'openssl-legacy-renegotiation.cnf'
  [System.IO.File]::WriteAllText($conf, "openssl_conf = openssl_init`n[openssl_init]`nssl_conf = ssl_sect`n[ssl_sect]`nsystem_default = system_default_sect`n[system_default_sect]`nOptions = UnsafeLegacyRenegotiation`n")
  $old = $env:OPENSSL_CONF
  try {
    $env:OPENSSL_CONF = $conf
    $out = & curl -sS --fail --max-time 20 -A $UA -H 'Accept-Language: zh-CN,zh;q=0.9' $url 2>&1
    if ($LASTEXITCODE -ne 0) { throw "curl 也抓不到（代码 $LASTEXITCODE）：$(($out | Out-String).Trim())" }
  } finally { $env:OPENSSL_CONF = $old }
  return (@($out) -join "`n")
}
# 把一个错误连同它内层的原因串成一行（像「SSL 连接建立失败」这种，真正的原因写在内层）
function Ex-Chain($e) {
  $parts = @()
  if ($e -is [Exception]) {
    while ($e -and ($parts.Count -lt 6)) { if ($parts -notcontains $e.Message) { $parts += $e.Message }; $e = $e.InnerException }
  } else { $parts = @("$e") }
  return ((($parts -join ' ← ') -replace '\s+', ' ').Trim())
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

# 每个来源除了 ok（连不连得上），还有 warn：连得上、但内容读不出来（多半是对方网页改版，解析规则要跟着改）
# 这种情况不提醒的话，会一直显示「无维护」而没人发现
# err 是连不上时的原因（最多 220 个字），网页页脚和 Telegram 提醒里会带上
# 连内层的原因一起记（见上面的 Ex-Chain）
function Err-Text($e) {
  $s = Ex-Chain $e
  if ($s.Length -gt 220) { $s = $s.Substring(0, 220) + '…' }
  return $s
}

# ============ 易宝支付：当前生效的公告列表 + 每条详情 ============
$n = 0; $ok = $false; $warn = ''; $err = ''; $badFmt = 0
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
      $winRx = '(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):\d{2}\s*--\s*(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):\d{2}'
      # 页面上明明有维护时间段，正文却切不出来：网页格式变了
      if ((-not $body) -and ($txt -match $winRx)) { $badFmt++; [void]$skipped.Add("易宝支付：$title（格式无法识别）"); continue }
      $wins = [regex]::Matches($body, $winRx)
      # 必须同时有「维护类关键词」和「明确的时间段」才算维护公告
      if (($wins.Count -eq 0) -or ("$title $body" -notmatch $KeepKw)) { [void]$skipped.Add("易宝支付：$title"); continue }
      $m = [regex]::Match($txt, '(\d{4}-\d{2}-\d{2})\s+尊敬的客户\s*(.+?)\s*[：:]\s*(.+?)\s*影响时间')
      if (-not $m.Success) { $badFmt++; [void]$skipped.Add("易宝支付：$title（格式无法识别）"); continue }
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
  # 这个列表平常一定有几条公告（声明、结算安排…），一条都抓不到就是列表页改版了
  if ($seen.Count -eq 0) { $warn = '公告列表抓到 0 条，网页格式可能已变' }
  elseif ($badFmt) { $warn = "$badFmt 条公告格式认不出，网页格式可能已变" }
} catch { $err = Err-Text $_.Exception; Write-Host "    易宝支付 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '易宝支付'; ok = $ok; count = $n; warn = $warn; err = $err })

# ============ 快钱：「最新银行维护通知」单页 ============
$n = 0; $ok = $false; $warn = ''; $err = ''
try {
  $url = 'https://help.99bill.com/index.php/%E5%BF%AB%E9%92%B1%E9%80%9A%E7%9F%A5/%E9%93%B6%E8%A1%8C%E9%A2%9D%E5%BA%A6%E8%B0%83%E6%95%B4%E9%80%9A%E7%9F%A5/2888-10%E6%9C%88%E6%9C%80%E6%96%B0%E9%93%B6%E8%A1%8C%E7%BB%B4%E6%8A%A4%E9%80%9A%E7%9F%A5.html'
  $page = Get-Page $url
  $txt = Strip-Html $page
  $ok = $true
  $rx = '接\s*(.{2,20}?)\s*通知，银行方将于\s*(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})[:：](\d{2})\s*[-—~至]+\s*(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})[:：](\d{2})\s*进行系统维护，届时我司\s*(.+?)\s*将受到影响'
  foreach ($m in [regex]::Matches($txt, $rx)) {
    $g = $m.Groups
    $bankName = $g[1].Value
    Add-Event $bankName (To-Ms $g[2].Value $g[3].Value $g[4].Value $g[5].Value $g[6].Value) (To-Ms $g[7].Value $g[8].Value $g[9].Value $g[10].Value $g[11].Value) 'stop' ($g[12].Value.Trim()) "$($bankName -replace '\s','')系统维护通知" $url '快钱' ''
    $n++
  }
  # 每条通知都有「银行方将于」这句：页面上有几句、规则却认出比较少条，就是有通知的写法变了
  $loose = [regex]::Matches($txt, '银行方将于').Count
  if ([regex]::Match($page, '(?s)<title>(.*?)</title>').Groups[1].Value -notmatch '银行维护通知') { $warn = '页面不是银行维护通知，网址可能已失效' }
  elseif ($loose -gt $n) { $warn = "有 $($loose - $n) 条通知格式认不出" }
} catch { $err = Err-Text $_.Exception; Write-Host "    快钱 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '快钱'; ok = $ok; count = $n; warn = $warn; err = $err })

# ============ 银行官网公告（中国银行 / 招商银行 / 中信银行 / 建设银行） ============
# 官方来源，但讲的是「部分服务可能受影响」，不等于通道不可用。
# 所以另外标成 partial：网页显示黄色、不算「维护中」，Telegram 每条公告只提醒一次。
$OffKw   = '维护|升级|暂停|停机'      # 标题要像维护公告
# 正文要提到跟收付款有关的服务才收（只影响贷款、信用卡补卡之类的不收）
$OffRel  = '快捷|支付|跨行|转账|代收|代付|网银|手机银行|银联|清算|零售业务|对公业务'
$OffDays = 45                        # 只看最近多少天内发布的公告
$OffMax  = 6                         # 每家银行最多打开几篇公告的正文
$offCut  = (Get-Date).AddDays(-$OffDays)

# 只留「尊敬的客户」到落款之间的正文，避免把页面其他地方的日期也抓进来
function Cut-Body($txt) {
  $i = $txt.IndexOf('尊敬的客户'); if ($i -lt 0) { $i = $txt.IndexOf('尊敬的') }; if ($i -lt 0) { $i = 0 }
  $t = $txt.Substring($i)
  $m = [regex]::Match($t, '特此公告|特此通告|银行股份有限公司')
  if ($m.Success) { $t = $t.Substring(0, $m.Index) }
  return $t
}
# 从公告正文抓出所有时间段（北京时间），回传 s / e 毫秒时间戳。认得这些写法：
#   9月13日00:00至05:00　　9月12日22:00至9月13日06:00　　9月13日2:00-9月13日3:40
#   2026年9月23日、11月24日、11月26日00:00～06:00（几个日期共用一个时段）
#   9月15日22:00～次日00:00　　8月16日04:30至04:35以及05:00至05:10（同一天好几段）
function Get-Windows($text, [datetime]$pub) {
  $t = $text -replace '\s', '' -replace '：', ':' -replace '[～〜]', '~' -replace '（', '(' -replace '）', ')'
  $t = [regex]::Replace($t, '\((?:星期|周)[一二三四五六日天]\)', '')
  $sep = '(?:至|到|-|—|–|~)'
  $rx = "(?<dates>(?:(?:\d{4}年)?\d{1,2}月\d{1,2}日、?)+)(?<h1>\d{1,2}):(?<m1>\d{2})$sep(?:(?<next>次日)|(?:(?<y2>\d{4})年)?(?<mo2>\d{1,2})月(?<d2>\d{1,2})日)?(?<h2>\d{1,2}):(?<m2>\d{2})(?<more>(?:(?:、|以及|和|及)\d{1,2}:\d{2}$sep\d{1,2}:\d{2})*)"
  $raw = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($t, $rx)) {
    $explicit = $null
    foreach ($dm in [regex]::Matches($m.Groups['dates'].Value, '(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日')) {
      $mo = [int]$dm.Groups[2].Value; $d = [int]$dm.Groups[3].Value
      if ($dm.Groups[1].Success) { $explicit = [int]$dm.Groups[1].Value }
      # 没写年份：用发布那一年；月份比发布月份小很多的，是跨年到明年
      $y = if ($explicit) { $explicit } elseif ($mo -lt $pub.Month - 6) { $pub.Year + 1 } else { $pub.Year }
      try { $day = New-Object datetime $y, $mo, $d } catch { continue }
      $s = $day.AddHours([int]$m.Groups['h1'].Value).AddMinutes([int]$m.Groups['m1'].Value)
      if ($m.Groups['d2'].Success) {
        $y2 = if ($m.Groups['y2'].Success) { [int]$m.Groups['y2'].Value } else { $y }
        try { $e = (New-Object datetime $y2, ([int]$m.Groups['mo2'].Value), ([int]$m.Groups['d2'].Value)).AddHours([int]$m.Groups['h2'].Value).AddMinutes([int]$m.Groups['m2'].Value) } catch { continue }
        if ($e -lt $s) { $e = $e.AddYears(1) }
      } else {
        $e = $day.AddHours([int]$m.Groups['h2'].Value).AddMinutes([int]$m.Groups['m2'].Value)
        if ($m.Groups['next'].Success -or ($e -le $s)) { $e = $e.AddDays(1) }
      }
      [void]$raw.Add([pscustomobject]@{ s = $s; e = $e })
      foreach ($x in [regex]::Matches($m.Groups['more'].Value, "(\d{1,2}):(\d{2})$sep(\d{1,2}):(\d{2})")) {
        $s2 = $day.AddHours([int]$x.Groups[1].Value).AddMinutes([int]$x.Groups[2].Value)
        $e2 = $day.AddHours([int]$x.Groups[3].Value).AddMinutes([int]$x.Groups[4].Value)
        if ($e2 -le $s2) { $e2 = $e2.AddDays(1) }
        [void]$raw.Add([pscustomobject]@{ s = $s2; e = $e2 })
      }
    }
  }
  # 不合理的丢掉：长度超过 7 天，或离发布日太远
  $ok = @($raw | Where-Object { ($_.e -gt $_.s) -and (($_.e - $_.s).TotalDays -le 7) -and ($_.s -ge $pub.AddDays(-2)) -and ($_.s -le $pub.AddDays(150)) } | Sort-Object s)
  # 同一篇公告里重叠或相隔 3 小时内的时间段并成一段（一篇公告常常列十几项服务，各有各的时段）
  $merged = New-Object System.Collections.ArrayList
  foreach ($w in $ok) {
    if ($merged.Count -and ($w.s -le $merged[$merged.Count - 1].e.AddHours(3))) {
      if ($w.e -gt $merged[$merged.Count - 1].e) { $merged[$merged.Count - 1].e = $w.e }
    } else { [void]$merged.Add([pscustomobject]@{ s = $w.s; e = $w.e }) }
  }
  $epoch = New-Object datetime 1970, 1, 1
  return @($merged | ForEach-Object { [pscustomobject]@{ s = [int64](($_.s - $epoch).TotalMilliseconds) - 28800000; e = [int64](($_.e - $epoch).TotalMilliseconds) - 28800000 } })
}
# 一篇官网公告 → 维护时间段；回传收了几段
function Add-Official($bank, $src, $title, $url, [datetime]$pub, $body) {
  $rel = @([regex]::Matches($body, $OffRel) | ForEach-Object { $_.Value } | Select-Object -Unique)
  if (-not $rel.Count) { [void]$skipped.Add("${src}：$title（没提到收付款相关的服务，不收）"); return 0 }
  $wins = @(Get-Windows $body $pub)
  if (-not $wins.Count) { [void]$skipped.Add("${src}：$title（抓不到明确的时间段，不收）"); return 0 }
  $scope = '部分服务可能受影响（公告提到：' + (($rel | Select-Object -First 5) -join '、') + '）'
  foreach ($w in $wins) { Add-Event $bank $w.s $w.e 'partial' $scope $title $url $src $pub.ToString('yyyy-MM-dd') }
  return $wins.Count
}
function Fetch-BOC($bank, $src) {
  $base = 'https://www.boc.cn/custserv/bi2/'; $n = 0; $k = 0
  $h = Get-PageRetry $base
  $ms = [regex]::Matches($h, '(?s)<li>\s*<a href="([^"]+)"[^>]*title="([^"]*)"[^>]*>.*?</a>\s*<span>\[\s*(\d{4}-\d{2}-\d{2})\s*\]</span>')
  $script:offListN = $ms.Count
  foreach ($m in $ms) {
    $title = $m.Groups[2].Value.Trim(); $pub = [datetime]::ParseExact($m.Groups[3].Value, 'yyyy-MM-dd', $null)
    if (($title -notmatch $OffKw) -or ($pub -lt $offCut)) { continue }
    $k++; if ($k -gt $OffMax) { break }
    $url = (New-Object System.Uri((New-Object System.Uri($base)), $m.Groups[1].Value)).AbsoluteUri
    Start-Sleep -Milliseconds 300
    try {
      $d = Get-PageRetry $url
      $mm = [regex]::Match($d, '(?s)<div class="sub_con"[^>]*>(.*)')
      $n += (Add-Official $bank $src $title $url $pub (Cut-Body (Strip-Html $(if ($mm.Success) { $mm.Groups[1].Value } else { $d }))))
    } catch { Write-Host "    $src 公告正文抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  return $n
}
function Fetch-CMB($bank, $src) {
  $n = 0; $resp = $null
  foreach ($try in 1, 2) {
    try { $resp = Invoke-WebRequest -Uri 'https://www.cmbchina.com/api/v1/cms/list/paged' -Method Post -Body '{"web":"cmbNotice","pageIndex":1,"pageSize":30}' -ContentType 'application/json' -Headers @{ 'User-Agent'=$UA } -UseBasicParsing -TimeoutSec 15; break }
    catch { if ($try -eq 2) { throw }; Start-Sleep -Seconds 2 }
  }
  $j =[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
  foreach ($p in @($j.body.pages)) {
    if (-not $p) { continue }
    $script:offListN++
    $title = "$($p.title)".Trim()
    # 新版 PowerShell 读 JSON 时可能已经把时间转成 datetime，两种都要能处理
    $pub = if ($p.timeEffective -is [datetime]) { $p.timeEffective.Date } else { [datetime]::ParseExact("$($p.timeEffective)".Substring(0, 10), 'yyyy-MM-dd', $null) }
    if (($title -notmatch $OffKw) -or ($pub -lt $offCut)) { continue }
    # 列表接口直接带正文，不用再抓详情
    $n += (Add-Official $bank $src $title "https://www.cmbchina.com/main/noticeinfo.aspx?guid=$($p.guid)" $pub (Cut-Body (Strip-Html "$($p.contentInfo)")))
  }
  return $n
}
function Fetch-CITIC($bank, $src) {
  $n = 0; $k = 0
  $h = Get-PageRetry 'https://www.citicbank.com/common/servicenotice/'
  $ms = [regex]::Matches($h, '(?s)<a href="(https?://[^"]*servicenotice/\d{6}/t\d{8}_\d+\.html)"[^>]*>\s*(.*?)\s*</a>\s*<span>\s*(\d{4}-\d{2}-\d{2})\s*</span>')
  $script:offListN = $ms.Count
  foreach ($m in $ms) {
    $title = Strip-Html $m.Groups[2].Value; $pub = [datetime]::ParseExact($m.Groups[3].Value, 'yyyy-MM-dd', $null)
    if (($title -notmatch $OffKw) -or ($pub -lt $offCut)) { continue }
    $k++; if ($k -gt $OffMax) { break }
    Start-Sleep -Milliseconds 300
    try { $n += (Add-Official $bank $src $title $m.Groups[1].Value $pub (Cut-Body (Strip-Html (Get-PageRetry $m.Groups[1].Value)))) }
    catch { Write-Host "    $src 公告正文抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  return $n
}
function Fetch-CCB($bank, $src) {
  $n = 0; $k = 0
  $h = Get-PageRetry 'https://www.ccb.com/chn/home/notice/zxgg.shtml'
  $ms = [regex]::Matches($h, '(?s)<a\s[^>]*href="(/chn/\d{4}-\d{2}/\d{2}/article_[^"]+\.shtml)"[^>]*class="blue3"[^>]*>(.*?)</a>\s*(?:<[^>]+>\s*)*?(\d{4}-\d{2}-\d{2})')
  $script:offListN = $ms.Count
  foreach ($m in $ms) {
    $title = [regex]::Match($m.Value, '\stitle="([^"]+)"').Groups[1].Value.Trim()
    if (-not $title) { $title = (Strip-Html $m.Groups[2].Value) -replace '^[•\s]+', '' }
    $pub = [datetime]::ParseExact($m.Groups[3].Value, 'yyyy-MM-dd', $null)
    if (($title -notmatch $OffKw) -or ($pub -lt $offCut)) { continue }
    $k++; if ($k -gt $OffMax) { break }
    $url = 'https://www.ccb.com' + $m.Groups[1].Value
    Start-Sleep -Milliseconds 300
    try { $n += (Add-Official $bank $src $title $url $pub (Cut-Body (Strip-Html (Get-PageRetry $url)))) }
    catch { Write-Host "    $src 公告正文抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  return $n
}
foreach ($o in @(
  @{ bank = '中国银行'; fn = 'Fetch-BOC' }, @{ bank = '招商银行'; fn = 'Fetch-CMB' },
  @{ bank = '中信银行'; fn = 'Fetch-CITIC' }, @{ bank = '建设银行'; fn = 'Fetch-CCB' }
)) {
  if (-not (Find-Bank $o.bank)) { continue }   # 后台没启用的银行不抓
  $src = "$($o.bank)官网"; $n = 0; $ok = $false; $warn = ''; $err = ''
  $script:offListN = 0   # 各家的抓取函数会把「公告列表认出几条」写在这里
  try {
    $n = & $o.fn $o.bank $src; $ok = $true
    # 银行官网的公告列表不会是空的，一条都认不出就是列表页改版了
    if ($script:offListN -eq 0) { $warn = '公告列表抓到 0 条，网页格式可能已变' }
  } catch { $err = Err-Text $_.Exception; Write-Host "    $src 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  [void]$sources.Add([pscustomobject]@{ name = $src; ok = $ok; count = $n; warn = $warn; err = $err })
}

# ============ 支付宝开放平台公告（只留近一年的维护 / 异常类） ============
$aliNotices = New-Object System.Collections.ArrayList
$n = 0; $ok = $false; $warn = ''; $err = ''
try {
  $aj = (Get-Page $cfg.alipay.notice_url) | ConvertFrom-Json
  $ok = $true
  if (@($aj.announcement | Where-Object { $_ }).Count -eq 0) { $warn = '公告列表是空的，接口格式可能已变' }
  $yearAgo = [DateTimeOffset]::UtcNow.AddYears(-1).ToUnixTimeMilliseconds()
  foreach ($a in $aj.announcement) {
    $pubMs = [int64]$a.releaseDate
    if ($pubMs -lt $yearAgo) { continue }
    if (($a.title -notmatch $cfg.alipay.keep) -or ($a.title -match $cfg.alipay.drop)) { [void]$skipped.Add("支付宝：$($a.title)"); continue }
    [void]$aliNotices.Add([pscustomobject]@{ title = [string]$a.title; url = [string]$a.link; pub = $pubMs; src = '支付宝开放平台' })
    $n++
  }
} catch { $err = Err-Text $_.Exception; Write-Host "    支付宝公告 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
[void]$sources.Add([pscustomobject]@{ name = '支付宝开放平台'; ok = $ok; count = $n; warn = $warn; err = $err })

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

foreach ($s in $sources) {
  if ($s.ok -and $s.warn) { Write-Host ("  {0}：连得上，但{1}" -f $s.name, $s.warn) -ForegroundColor DarkYellow }
  else { Write-Host ("  {0}：{1}，收录 {2} 条" -f $s.name, $(if ($s.ok) { '连接正常' } else { '连接失败' }), $s.count) -ForegroundColor Green }
}
Write-Host "  完成：启用银行相关 $($final.Count) 个维护时间段；未启用/未识别 $(@($unmatched | Select-Object -Unique).Count) 家" -ForegroundColor Green
Write-Host "  已过滤非维护类公告 $($skipped.Count) 条：" -ForegroundColor DarkGray
foreach ($k in $skipped) { Write-Host "    - $k" -ForegroundColor DarkGray }
