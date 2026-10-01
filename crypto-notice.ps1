# -*- coding: utf-8 -*-
# 监控台：虚拟币 / 网银·支付宝 / 银行 三个分页
# 虚拟币：抓取 币安(Binance) + 欧易(OKX) + Coinbase 公告，过滤出充提维护相关
# 银行 / 支付宝：由同目录的 bank-fetch.ps1 抓取（名单与关键词在 banks.json）
# 生成网页并自动打开
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
# TRON / TRC 前后不能紧挨英文字母，否则 Neutron（NTRN）会被当成 TRON
# Toncoin 已改名 Gram（GRAM），两种叫法都算 TON 链
$ChainMap = [ordered]@{
  'TRON' = '(?<![A-Za-z])TRON(?![A-Za-z])|(?<![A-Za-z])TRC(?:-?20)?(?![A-Za-z])|波场|波場'
  'BSC'  = '\bBSC\b|BEP20|BEP-20|BNB Smart|BNB Chain|币安智能链|幣安智能鏈|BNB链|BNB鏈|OpBNB'
  'ETH'  = 'ERC20|ERC-20|以太坊|Ethereum|ETH网络|ETH網絡'
  'TON'  = 'Toncoin|TON网络|TON網絡|TON链|TON鏈|The Open Network|\bTON\b|(?<![A-Za-z])GRAM(?![A-Za-z])'
  'SOL'  = 'Solana|SOLANA|\bSPL\b|SOL网络|SOL網絡|索拉纳|\bSOL\b'
}

# 严格过滤：只要「涉及5链的充提/维护」或「交易所系统维护」
$StrictKw = '暂停|暫停|维护|維護|停机|停機|停充|停提|充值|儲值|提现|提幣|提币|充提|终止|終止|升级|升級|硬分叉|快照|snapshot|suspend|suspension|maintenance|deposit|withdraw|恢复|恢復|resume|Paused|Delayed|Sends|Receives|halt|hard fork|upgrade'
# 交易所整体维护（不依赖具体链）
$SysKw    = '系统维护|系統維護|系统升级|系統升級|平台维护|平台維護|停机维护|停機維護|系统公告|系統公告|系统故障|系統故障|System Maintenance|System Upgrade'
# 没点名哪条链的钱包 / 充提维护（「关于钱包维护的公告」「对部分网络 USDC 提现维护」）：可能波及目标链，也保留
$MultiKw  = '关于钱包维护|關於錢包維護|部分网络\S{0,16}维护|部分網[絡路]\S{0,16}維護'
# 明确排除（活动/理财等杂项，命中即丢弃）
$ExcludeKw = '空投|理财|理財|竞赛|競賽|活动|活動|Alpha|HODLer|Launchpool|Megadrop|奖励|獎勵|瓜分|持币|持幣|盘前|盤前|Pre-IPO|返佣|限时|限時|理财竞技'
# 合约 / 杠杆 / 上新类：通常跟充提无关，也排除；
# 但标题同时提到「充提 / 钱包」又有「暂停 / 维护 / 升级」的（例如「合约升级暂停充提」），照样保留
$SoftExcludeKw = '合约|合約|风险限额|風險限額|上线|上線|上市|杠杆|槓桿|保证金|保證金'
$WalletKw = '充值|儲值|充提|提现|提現|提币|提幣|停充|停提|钱包|錢包|deposit|withdraw|wallet'
$StopKw   = '暂停|暫停|维护|維護|停机|停機|停充|停提|停止|终止|終止|升级|升級|硬分叉|suspend|suspension|maintenance|halt|upgrade|hard fork'

# ============ Telegram 推送范围 ============
# 交易所公告：只有涉及这些链的才推 Telegram，其余只显示在网页上。要加别的链就写成 @('TRON', 'BSC')
# 链名要跟下面 $ChainMap 的名字一样：TRON / BSC / ETH / TON / SOL
$PushChains = @('TRON')

# ============ 链节点（网页的实时状态和 Telegram 的链异常检测共用这一份） ============
# nodes 按顺序试：只要有一个节点回报出块正常，这条链就算正常，所以每条链都放了备用节点
# web=$false 的节点只给脚本用（该节点不允许浏览器直连）
# bt  = 大约几秒出一个块（网页用来判断「变慢 / 停摆」）
# age = 超过多少秒没出新块，Telegram 就报异常
$ChainDefs = @(
  [ordered]@{ k='TRON'; n='TRON'; s='TRC20'; bt=3; age=180; nodes=@(
    [ordered]@{ t='tron'; u='https://api.trongrid.io/wallet/getnowblock' },
    [ordered]@{ t='tron'; u='https://tron-rpc.publicnode.com/wallet/getnowblock' }
  ) },
  [ordered]@{ k='BSC'; n='BSC'; s='BEP20'; bt=3; age=120; nodes=@(
    [ordered]@{ t='evm'; u='https://bsc-rpc.publicnode.com' },
    [ordered]@{ t='evm'; u='https://bsc-dataseed.bnbchain.org' }
  ) },
  [ordered]@{ k='ETH'; n='Ethereum'; s='ERC20'; bt=12; age=300; nodes=@(
    [ordered]@{ t='evm'; u='https://ethereum-rpc.publicnode.com' },
    [ordered]@{ t='evm'; u='https://eth.drpc.org' }
  ) },
  [ordered]@{ k='SOL'; n='Solana'; s='SPL'; bt=2; age=120; nodes=@(
    [ordered]@{ t='sol'; u='https://solana-rpc.publicnode.com' },
    [ordered]@{ t='sol'; u='https://api.mainnet-beta.solana.com'; web=$false },
    [ordered]@{ t='sol'; u='https://solana-mainnet.gateway.tatum.io' }
  ) },
  [ordered]@{ k='TON'; n='TON'; s='TON'; bt=5; age=180; nodes=@(
    [ordered]@{ t='ton'; u='https://toncenter.com/api/v3/masterchainInfo' },
    [ordered]@{ t='tonapi'; u='https://tonapi.io/v2/blockchain/masterchain-head' }
  ) }
)

# ============ 时间：虚拟币分页一律用北京时间（跟银行分页一致），不管脚本跑在哪个时区的机器上 ============
# 接受 DateTimeOffset / DateTime / ISO 字符串，回传北京时间
function To-BJ($v) {
  if ($v -is [DateTimeOffset]) { $dto = $v }
  elseif ($v -is [datetime]) { $dto = [DateTimeOffset]$v }
  else { $dto = [DateTimeOffset]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture) }
  return $dto.ToOffset([TimeSpan]::FromHours(8)).DateTime
}
$nowBJ = To-BJ ([DateTimeOffset]::UtcNow)

function Get-Chains($title) {
  $found = @()
  foreach ($k in $ChainMap.Keys) { if ($title -match $ChainMap[$k]) { $found += $k } }
  return $found
}
function Get-Level($title, $t) {
  # 新增网络 / 代币支持（「完成…网络集成，并开放充值」）不是恢复，只算相关
  if ($title -match '网络集成|網絡集成|網路整合|专属充值地址|專屬充值地址') { return 'info' }
  # 「完成后 / 完成之后」是预告，不算已完成
  $doneKw   = '已恢复|已恢復|已完成|已重新|现已|現已|(?:维护|維護|升级|升級)完成(?!后|後|之后|之後)|resumed|completed|restored'
  $isResume = $title -match "恢復|恢复|重新开放|重新開放|开放充值|開放充值|resume|$doneKw"
  $isStop   = $title -match '暂停|暫停|停止|停机|停機|停充|停提|維護|维护|suspend|suspension|paused|halt|delayed|maintenance'
  # 「暂停」和「恢复」同时出现时：写明已恢复 / 已完成、又不是预告的才算恢复；
  # 其余（「将暂停…完成后恢复」这类）一律当成维护 / 暂停 —— 宁可多提醒，也不要漏掉
  if ($isResume -and $isStop -and (($title -notmatch $doneKw) -or ($title -match '将|將|计划|計劃|预计|預計|will|scheduled|upcoming'))) { $isResume = $false }
  # 明确"已恢复/已完成"
  if ($isResume) { return 'resume' }
  # "暂停/停机/维护"类（真正需要注意的）
  if ($isStop) {
    # 超过 3 天前的不再红色警报；公告没说已恢复，所以只标「已过去」，不标「已恢复」
    if ($t -and ($t -lt $nowBJ.AddDays(-3))) { return 'past' }
    return 'alert'
  }
  # 升级 / 硬分叉（专属标签）
  if ($title -match '升级|升級|硬分叉|hard fork|upgrade') { return 'upgrade' }
  # 其他（支持公告等）= 中性
  return 'info'
}
# 保留条件：涉及5链且是充提/维护语境，或交易所系统维护
# 本来会收、但被排除词挡掉的，标题记进 $cxSkipped，方便核对有没有误杀
$cxSkipped = New-Object System.Collections.ArrayList
function Should-Keep($title, $ex) {
  $hit = ($title -match $SysKw) -or (($title -match $StrictKw) -and ((Get-Chains $title).Count -gt 0)) -or ($title -match $MultiKw)
  if (-not $hit) { return $false }
  $drop = ($title -match $ExcludeKw) -or (($title -match $SoftExcludeKw) -and -not (($title -match $WalletKw) -and ($title -match $StopKw)))
  if ($drop) {
    $line = "${ex}：$title"
    if (-not $cxSkipped.Contains($line)) { [void]$cxSkipped.Add($line) }
    return $false
  }
  return $true
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
  $t = $t -replace 'Scheduled System Upgrade','计划系统升级'
  $t = $t -replace 'System Upgrade','系统升级'
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
# 发送 Telegram 消息（UTF-8 JSON），成功返回 $true；失败的不会记为已推送，下次运行再试
# 本机测试时设环境变量 TG_DRYRUN=1：只把消息印在屏幕上，不真的发送
# TG_CHAT 可以填多个对象（私聊、群组），用逗号隔开，每个都会发
# 只要有一个发成功就算成功：否则某个对象一直发不出去时，其他对象会每 5 分钟重复收到同一条
function Send-TGOk($token, $chat, $text) {
  $targets = @("$chat" -split '[,，;；\s]+' | Where-Object { $_ })
  if ($env:TG_DRYRUN) { Write-Host "  [演练 → $($targets.Count) 个对象] $($text -replace "`n", ' ｜ ')" -ForegroundColor Magenta; return $true }
  $ok = $false; $i = 0
  foreach ($c in $targets) {
    $i++
    $p = @{ chat_id = $c; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    try {
      Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($p)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
      $ok = $true
    } catch { Write-Host "  Telegram 推送失败（第 $i 个对象）: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  return $ok
}
function Send-TG($token, $chat, $text) { [void](Send-TGOk $token $chat $text) }
# 毫秒时间戳 → 北京时间 MM-dd HH:mm
function Fmt-BJ($ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm') }
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
      # getHealth 只是跟其他节点比进度，整条链一起停摆时照样回 ok，所以改看最新区块的出块时间
      $s = Invoke-RestMethod -Uri $url -Method Post -Body '{"jsonrpc":"2.0","method":"getSlot","params":[{"commitment":"confirmed"}],"id":1}' -ContentType 'application/json' -TimeoutSec 15
      $b = Invoke-RestMethod -Uri $url -Method Post -Body ('{"jsonrpc":"2.0","method":"getBlockTime","params":[' + [int64]$s.result + '],"id":1}') -ContentType 'application/json' -TimeoutSec 15
      if ($b.result) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$b.result
        if ($age -le $maxAgeSec) { return $null } else { return "出块停滞约 $([int]$age) 秒" }
      }
      # 偶尔取不到出块时间：退回用节点健康状态判断
      $r = Invoke-RestMethod -Uri $url -Method Post -Body '{"jsonrpc":"2.0","method":"getHealth","id":1}' -ContentType 'application/json' -TimeoutSec 15
      if ($r.result -eq 'ok') { return $null } else { return "节点健康异常" }
    }
    if ($type -eq 'ton') {
      # v3 接口带最新主链区块的生成时间，可以看出链有没有停
      $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
      if (-not $r.last.gen_utime) { return "无法获取区块" }
      $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$r.last.gen_utime
      if ($age -le $maxAgeSec) { return $null } else { return "出块停滞约 $([int]$age) 秒" }
    }
    if ($type -eq 'tonapi') {
      # TON 的备用来源（tonapi.io），栏位名跟 toncenter 不一样
      $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
      if (-not $r.gen_utime) { return "无法获取区块" }
      $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$r.gen_utime
      if ($age -le $maxAgeSec) { return $null } else { return "出块停滞约 $([int]$age) 秒" }
    }
    return $null
  } catch { return "连接失败/无响应" }
}
# 检测一条链（$ChainDefs 里的一项）：按顺序试每个节点，有一个回报出块正常就算正常，回传 $null
# 都不正常时回传 kind + reason：
#   stall = 有节点连得上、但出块停滞（链本身可能出问题）
#   down  = 所有节点都没有正常回应（看不出链的状态，不一定是链的问题）
function Test-ChainDef($def) {
  $stall = $null; $other = $null
  foreach ($nd in $def.nodes) {
    $r = Test-Chain $nd.t $nd.u $def.age
    if (-not $r) { return $null }
    if ($r -match '^出块停滞') { if (-not $stall) { $stall = $r } } else { $other = $r }
  }
  if ($stall) { return [pscustomobject]@{ kind = 'stall'; reason = $stall } }
  return [pscustomobject]@{ kind = 'down'; reason = "$(@($def.nodes).Count) 个检测节点都没有正常回应（$other）" }
}

# 每家交易所的抓取情况：okN = 成功拿到数据的请求数，failN = 失败的请求数（只算第一页，新公告都在第一页）
$cxNames = @{ Binance = '币安'; OKX = '欧易'; Coinbase = 'Coinbase' }
$cxSrc = [ordered]@{}
foreach ($k in 'Binance', 'OKX', 'Coinbase') { $cxSrc[$k] = [pscustomobject]@{ name = $k; okN = 0; failN = 0; err = '' } }
# 把失败原因记下来（最多 160 个字），网页页脚和 Telegram 提醒里都会带上，不用翻运行日志就知道为什么抓不到
function Short-Err($m) { $s = ("$m" -replace '\s+', ' ').Trim(); if ($s.Length -gt 160) { $s = $s.Substring(0, 160) + '…' }; return $s }

# 币安公告的发布时间缓存（bn-dates.txt，一行一条：公告编号|毫秒时间戳|d 或 f）
#   d = 从详情接口查到的真正发布时间，以后不用再查
#   f = 详情接口查不到时，用「第一次看到这篇公告」的时间顶替，之后每次运行会再试着查
$bnDateFile = Join-Path $ScriptDir 'bn-dates.txt'
$bnDates = [ordered]@{}; $bnSeen = @{}; $bnNoDate = 0
if (Test-Path $bnDateFile) {
  foreach ($ln in @(Get-Content $bnDateFile -Encoding UTF8)) {
    $p = "$ln".Trim().Split('|')
    if (($p.Count -ge 3) -and $p[0]) { try { $bnDates[$p[0]] = [pscustomobject]@{ ms = [int64]$p[1]; k = $p[2] } } catch {} }
  }
}
$bnBoot = ($bnDates.Count -eq 0)   # 还没有缓存（第一次运行）：分不出哪些是新公告
function Ms-ToBJ($ms) { return (To-BJ ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms))) }

$items = New-Object System.Collections.ArrayList

# ============ 币安 Binance ============
$bnHeaders = @{ 'Accept'='application/json'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'lang'='zh-CN'; 'clienttype'='web' }
# 币安用 catalog/list/query（可返回多条）；48=上币 49=最新消息 161=上新 128/93=其他
# 列表接口不给发布时间：先取标题里的日期；标题没有日期的，再查这篇公告的详情拿真正的发布时间
foreach ($cid in 48,49,157,161,128,93) {
  foreach ($pno in 1,2,3,4) {
    Start-Sleep -Milliseconds 200
    try {
      $r = Get-Json "https://www.binance.com/bapi/composite/v1/public/cms/article/catalog/list/query?catalogId=$cid&pageNo=$pno&pageSize=50" $bnHeaders
      if (-not $r.data.articles -or @($r.data.articles).Count -eq 0) { break }
      $cxSrc['Binance'].okN++
      foreach ($a in $r.data.articles) {
        if (Should-Keep $a.title 'Binance') {
          # 币安中文公告标题里的日期就是东八区（北京时间）的日期；只有日期没有钟点，网页上只显示日期
          $t = $null; $dateOnly = $false
          if ($a.title -match '(\d{4}-\d{2}-\d{2})') { try { $t = [datetime]::ParseExact($matches[1],'yyyy-MM-dd',$null); $dateOnly = $true } catch {} }
          if (-not $t) {
            $code = [string]$a.code; $bnSeen[$code] = $true
            $c = $bnDates[$code]
            if ($c -and ($c.k -eq 'd')) { $t = Ms-ToBJ $c.ms }
            else {
              try {
                Start-Sleep -Milliseconds 200
                $det = Get-Json "https://www.binance.com/bapi/composite/v1/public/cms/article/detail/query?articleCode=$code" $bnHeaders
                if ($det.data.publishDate) {
                  $t = Ms-ToBJ $det.data.publishDate
                  $bnDates[$code] = [pscustomobject]@{ ms = [int64]$det.data.publishDate; k = 'd' }
                }
              } catch {}
              if (-not $t) {
                # 查不到发布时间：以前看到过的，沿用第一次看到的时间（不会把旧公告当成今天的新公告）
                if ($c) { $t = Ms-ToBJ $c.ms }
                # 从没看到过的才是新公告，把现在记成它的时间
                elseif (-not $bnBoot) { $bnDates[$code] = [pscustomobject]@{ ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); k = 'f' }; $t = $nowBJ }
                # 第一次运行分不出新旧：先跳过，下次运行再查
                else { $bnNoDate++; continue }
              }
            }
          }
          [void]$items.Add([pscustomobject]@{
            Exchange = 'Binance'
            DateOnly = $dateOnly
            Time     = $t
            Title    = [string]$a.title
            Url      = "https://www.binance.com/zh-CN/support/announcement/$($a.code)"
            Chains   = (Get-Chains $a.title)
            Level    = (Get-Level $a.title $t)
          })
        }
      }
    } catch {
      if ($pno -eq 1) { $cxSrc['Binance'].failN++; $cxSrc['Binance'].err = Short-Err $_.Exception.Message }
      Write-Host "    币安分类 $cid 第 $pno 页抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
  }
}
if ($bnNoDate) { Write-Host "    币安有 $bnNoDate 条公告查不到发布时间，这次先跳过，下次运行再查" -ForegroundColor DarkYellow }
# 存回缓存：这次用到的排在后面，最多留 1000 条
try {
  # 第一次运行只要币安列表抓得到，就留一行记号：下次起不再算「第一次」，没看过的公告会当成新公告处理
  if ($bnBoot -and ($cxSrc['Binance'].okN -gt 0) -and (-not $bnDates.Contains('_init'))) { $bnDates['_init'] = [pscustomobject]@{ ms = 0; k = 'x' } }
  $keys =@($bnDates.Keys | Where-Object { -not $bnSeen[$_] }) + @($bnDates.Keys | Where-Object { $bnSeen[$_] })
  @($keys | Select-Object -Last 1000 | ForEach-Object { "$_|$($bnDates[$_].ms)|$($bnDates[$_].k)" }) | Out-File -FilePath $bnDateFile -Encoding UTF8
} catch { Write-Host "    币安时间缓存写入失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

# ============ 欧易 OKX（充提暂停/恢复专属分类） ============
$okxHeaders = @{ 'Accept'='application/json'; 'Accept-Language'='zh-CN'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
# 欧易的公告接口有两个官方域名，内容一样：第一个抓不到就换第二个
# （脚本跑在 GitHub 的服务器上，那边连得上哪个域名，跟你自己的电脑打不打得开欧易无关）
$okxHosts = @('www.okx.com', 'eea.okx.com'); $okxHost = $null   # $okxHost = 这次运行已经确认抓得到的域名
foreach ($pg in 1..5) {
  Start-Sleep -Milliseconds 400
  $r = $null; $why = @()
  foreach ($hst in $(if ($okxHost) { @($okxHost) } else { $okxHosts })) {
    try {
      $x = Get-Json "https://$hst/api/v5/support/announcements?annType=announcements-deposit-withdrawal-suspension-resumption&page=$pg" $okxHeaders
      if ($x.data.Count -gt 0) { $r = $x; $okxHost = $hst; break }
      # 接口有回应、但没给数据（例如被限流或地区限制时回传的错误码）
      $why += "$hst 没有回传数据 code=$($x.code) $($x.msg)"
    } catch { $why += "$hst $($_.Exception.Message)" }
  }
  if (-not $r) {
    if ($pg -eq 1) { $cxSrc['OKX'].failN++; $cxSrc['OKX'].err = Short-Err ($why -join '；') }
    Write-Host "    欧易第 $pg 页抓取失败: $($why -join '；')" -ForegroundColor DarkYellow
    continue
  }
  $cxSrc['OKX'].okN++
  try {
    foreach ($d in $r.data[0].details) {
      if (-not (Should-Keep $d.title 'OKX')) { continue }
      $t = try { To-BJ ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$d.pTime)) } catch { $nowBJ }
      [void]$items.Add([pscustomobject]@{
        Exchange = 'OKX'
        Time     = $t
        Title    = [string]$d.title
        Url      = [string]$d.url
        Chains   = (Get-Chains $d.title)
        Level    = (Get-Level $d.title $t)
      })
    }
  } catch { Write-Host "    欧易第 $pg 页内容处理失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

# ============ Coinbase（状态页：充提事件 + 计划维护） ============
$cbHeaders = @{ 'Accept'='application/json'; 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
# 充提暂停/延迟等事件
try {
  $inc = Get-Json "https://status.coinbase.com/api/v2/incidents.json" $cbHeaders
  $cxSrc['Coinbase'].okN++
  foreach ($e in $inc.incidents) {
    if (Should-Keep $e.name 'Coinbase') {
      $t = try { To-BJ $e.created_at } catch { $nowBJ }
      $lv = if ($e.status -match 'resolved|completed|postmortem') { 'resume' } else { 'alert' }
      [void]$items.Add([pscustomobject]@{
        Exchange = 'Coinbase'; Time = $t; Title = (Translate-CB ([string]$e.name)); Url = [string]$e.shortlink
        Chains = (Get-Chains $e.name); Level = $lv
      })
    }
  }
} catch { $cxSrc['Coinbase'].failN++; $cxSrc['Coinbase'].err = Short-Err $_.Exception.Message; Write-Host "    Coinbase 事件抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }
# 计划维护
try {
  $mnt = Get-Json "https://status.coinbase.com/api/v2/scheduled-maintenances.json" $cbHeaders
  $cxSrc['Coinbase'].okN++
  foreach ($e in $mnt.scheduled_maintenances) {
    if (Should-Keep $e.name 'Coinbase') {
      $t = try { To-BJ $e.scheduled_for } catch { $nowBJ }
      $lv = if ($e.status -match 'completed') { 'resume' } else { 'alert' }
      [void]$items.Add([pscustomobject]@{
        Exchange = 'Coinbase'; Time = $t; Title = (Translate-CB ([string]$e.name)); Url = [string]$e.shortlink
        Chains = (Get-Chains $e.name); Level = $lv
      })
    }
  }
} catch { $cxSrc['Coinbase'].failN++; $cxSrc['Coinbase'].err = Short-Err $_.Exception.Message; Write-Host "    Coinbase 维护抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

# ============ OKX 场外 USDT/CNY 快照（买入价 / 卖出价） ============
$okxBuy='—'; $okxSell='—'
try {
  $tms=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  # 取最优 10 档的中位价：只取最优那一档的话，偶尔会被单笔门槛很高的广告带偏（出现买入价比卖出价还低）
  # side=sell：商家卖USDT = 你买入USDT的价（越低越优）
  $sd=Get-Json "https://www.okx.com/v3/c2c/tradingOrders/books?t=$tms&quoteCurrency=CNY&baseCurrency=USDT&side=sell&paymentMethod=all&userType=all&showTrade=false&showFollow=false&showAlreadyTraded=false&isAbleFilter=false&currentPage=1&numberPerPage=10" $okxHeaders
  $sp=@($sd.data.sell | ForEach-Object { [double]$_.price } | Sort-Object | Select-Object -First 10)
  if ($sp.Count) { $okxBuy = ('{0:0.00}' -f (($sp[[int][Math]::Floor(($sp.Count - 1) / 2)] + $sp[[int][Math]::Floor($sp.Count / 2)]) / 2)) }
  # side=buy：商家买USDT = 你卖出USDT的价（越高越优）
  $bd=Get-Json "https://www.okx.com/v3/c2c/tradingOrders/books?t=$tms&quoteCurrency=CNY&baseCurrency=USDT&side=buy&paymentMethod=all&userType=all&showTrade=false&showFollow=false&showAlreadyTraded=false&isAbleFilter=false&currentPage=1&numberPerPage=10" $okxHeaders
  $bp=@($bd.data.buy | ForEach-Object { [double]$_.price } | Sort-Object -Descending | Select-Object -First 10)
  if ($bp.Count) { $okxSell = ('{0:0.00}' -f (($bp[[int][Math]::Floor(($bp.Count - 1) / 2)] + $bp[[int][Math]::Floor($bp.Count / 2)]) / 2)) }
  Write-Host "  OKX 场外 USDT：买入 $okxBuy / 卖出 $okxSell" -ForegroundColor Green
} catch { Write-Host "    OKX 场外价抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

# ============ 去重 + 只保留近一年 + 排序 ============
$oneYearAgo = $nowBJ.AddYears(-1)
$items = $items | Where-Object { $_.Time -ge $oneYearAgo } | Sort-Object Time -Descending | Group-Object Url | ForEach-Object { $_.Group[0] } | Sort-Object Time -Descending

$today = $nowBJ.Date
$todayAlerts = @($items | Where-Object { $_.Level -eq 'alert' -and $_.Time.Date -eq $today }).Count
$totalCount = @($items).Count
Write-Host "  完成：共 $totalCount 条相关公告，其中今日维护/暂停 $todayAlerts 条" -ForegroundColor Green

# ============ 公告来源有没有抓成功（抓不到时，「没有公告」不等于「正常」） ============
$cxDown = @($cxSrc.Values | Where-Object { $_.okN -eq 0 } | ForEach-Object { $cxNames[$_.name] })                        # 完全连不上
$cxPart = @($cxSrc.Values | Where-Object { ($_.okN -gt 0) -and ($_.failN -gt 0) } | ForEach-Object { $cxNames[$_.name] }) # 部分请求失败
$cxWarn = ''
if ($cxDown.Count -or $cxPart.Count) {
  $parts = @()
  # 措辞要讲清楚是「公告抓不到」，不是交易所本身出问题（交易所网站打得开，不代表脚本所在的服务器抓得到它的公告接口）
  if ($cxDown.Count) { $parts += "抓不到 $($cxDown -join '、') 的公告" }
  if ($cxPart.Count) { $parts += "$($cxPart -join '、') 的公告只抓到一部分" }
  $cxWarn = "公告抓取异常：$($parts -join '；')"
  Write-Host "  $cxWarn" -ForegroundColor DarkYellow
}
$cxSrcLine = @($cxSrc.Values | ForEach-Object {
  $why = if ($_.err) { "（$(Esc $_.err)）" } else { '' }
  $_.name + $(if ($_.okN -eq 0) { " ✗ 抓取失败$why" } elseif ($_.failN -gt 0) { " ⚠ 部分失败$why" } else { ' ✓' })
}) -join ' · '
if ($cxSkipped.Count) {
  Write-Host "  被排除词过滤掉的公告 $($cxSkipped.Count) 条：" -ForegroundColor DarkGray
  foreach ($k in $cxSkipped) { Write-Host "    - $k" -ForegroundColor DarkGray }
}

# ============ 生成公告行 HTML ============
$levelText = @{ 'alert'='维护/暂停'; 'resume'='已恢复'; 'past'='已过去'; 'upgrade'='升级'; 'info'='相关' }
$exClass   = @{ 'Binance'='ex-bn'; 'OKX'='ex-okx'; 'Coinbase'='ex-cb' }
$rowsSb = New-Object System.Text.StringBuilder
if ($totalCount -eq 0) {
  if ($cxWarn) { [void]$rowsSb.Append('<div class="empty" style="color:var(--warn)">公告来源抓取失败，目前无法判断有没有维护公告<br><span>请直接到交易所官网核实 · 每 5 分钟自动重试</span></div>') }
  else { [void]$rowsSb.Append('<div class="empty">当前无维护 / 暂停 / 升级相关公告<br><span>各链充提大概率正常 · 每 5 分钟自动更新</span></div>') }
} else {
  foreach ($it in $items) {
    $chainAttr = ($it.Chains -join ' ')
    $chipHtml = ''
    foreach ($c in $it.Chains) { $chipHtml += "<span class='chip'>$c</span>" }
    if (-not $chipHtml) { $chipHtml = "<span class='chip chip-none'>其他/多链</span>" }
    $isToday = if ($it.Time.Date -eq $today) { "<span class='today'>今天</span>" } else { '' }
    $timeStr = if ($it.DateOnly) { $it.Time.ToString('MM-dd') } else { $it.Time.ToString('MM-dd HH:mm') }
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

$updated = $nowBJ.ToString('yyyy-MM-dd HH:mm:ss')
$bannerClass = if ($todayAlerts -gt 0) { 'has-alert' } elseif ($cxWarn) { 'has-warn' } else { 'no-alert' }
$bannerText  = if ($todayAlerts -gt 0) { "今日发现 $todayAlerts 条维护 / 暂停公告，请留意相关链的充提" + $(if ($cxWarn) { "（另外$cxWarn，列表可能不完整）" } else { '' }) }
               elseif ($cxWarn) { "$cxWarn（是抓取程序连不上公告接口，不代表交易所本身有问题）—— 下面的列表不完整，没有公告不代表正常" }
               else { "今日暂无新的维护 / 暂停公告" }

# 被排除词过滤掉的公告：放在页脚，点开可以核对有没有误杀
$cxSkipHtml = ''
if ($cxSkipped.Count) {
  $cxSkipHtml = "<details class=`"skipbox`"><summary>另有 $($cxSkipped.Count) 条公告被排除词过滤（合约 / 活动 / 上新类），点开核对</summary><div>" + (@($cxSkipped | ForEach-Object { Esc $_ }) -join '<br>') + '</div></details>'
}
# 链节点名单给网页用：去掉只给脚本用的节点
$chainsJson = ConvertTo-Json -Depth 5 -Compress -InputObject @($ChainDefs | ForEach-Object {
  [ordered]@{ k = $_.k; n = $_.n; s = $_.s; bt = $_.bt; nodes = @($_.nodes | Where-Object { $_.web -ne $false } | ForEach-Object { [ordered]@{ t = $_.t; u = $_.u } }) }
})

# ============ HTML 模板 ============
$tpl = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>监控台</title>
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
  .card.lvl-info,.card.lvl-past{border-left-color:var(--faint)}
  .row1{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:7px}
  .ex{font-size:11px;font-weight:700;padding:2px 8px;border-radius:5px}
  .ex-bn{background:var(--gold);color:#1a1200}
  .ex-okx{background:#e9eef4;color:#0e141c}
  .ex-cb{background:#0052ff;color:#fff}
  .badge{font-size:11px;font-weight:600;padding:2px 8px;border-radius:5px}
  .b-alert{background:rgba(234,57,67,.15);color:#ff8a8f}
  .b-resume{background:rgba(22,199,132,.15);color:#5fe0aa}
  .b-upgrade{background:rgba(88,166,255,.15);color:#79b8ff}
  .b-info,.b-past{background:rgba(122,136,150,.15);color:var(--sub)}
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
  .skipbox{margin-top:8px}
  .skipbox summary{cursor:pointer;color:var(--sub)}
  .skipbox div{text-align:left;margin-top:8px;padding:10px 12px;border:1px solid var(--line);border-radius:8px;font-family:var(--sans);line-height:1.8}
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
  /* ====== 视图切换（虚拟币 / 银行·支付宝） ====== */
  .tabs{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;background:var(--line);border:1px solid var(--line);border-radius:10px;overflow:hidden;margin-bottom:20px;position:sticky;top:8px;z-index:60;box-shadow:0 10px 28px rgba(0,0,0,.55)}
  .tab{display:flex;align-items:center;gap:11px;background:var(--card);border:none;color:var(--sub);padding:12px 16px;cursor:pointer;font-family:var(--sans);text-align:left;position:relative;transition:background .12s,color .12s;min-width:0}
  .tab:hover{background:var(--card2);color:var(--txt)}
  .tab.active{background:var(--card2);color:var(--txt)}
  .tab.active::after{content:"";position:absolute;left:0;right:0;bottom:0;height:3px;background:var(--resume)}
  .tab[data-view="bank"].active::after{background:var(--accent)}
  .tab[data-view="alipay"].active::after{background:#1677ff}
  /* 支付宝网关的格子：栏数跟着 banks.json 里的网关数量走（c1 ~ c4） */
  .chaingrid.c1{grid-template-columns:1fr}
  .chaingrid.c2{grid-template-columns:repeat(2,1fr)}
  .chaingrid.c3{grid-template-columns:repeat(3,1fr)}
  .chaingrid.c4{grid-template-columns:repeat(4,1fr)}
  @media(max-width:680px){.chaingrid.c3,.chaingrid.c4{grid-template-columns:repeat(2,1fr)}}
  .tab svg{flex:none;opacity:.55}
  .tab.active svg{opacity:1}
  .tab-txt{display:flex;flex-direction:column;font-size:15px;font-weight:700;letter-spacing:-.01em;min-width:0}
  .tab-txt small{font-size:11.5px;font-weight:400;color:var(--sub);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .tab-badge{margin-left:auto;font-family:var(--mono);font-size:11.5px;font-weight:600;padding:3px 9px;border-radius:999px;border:1px solid var(--line2);color:var(--sub);white-space:nowrap;flex:none}
  .tab-badge.ok{color:var(--resume);border-color:rgba(22,199,132,.4);background:rgba(22,199,132,.07)}
  .tab-badge.warn{color:var(--warn);border-color:rgba(240,160,32,.45);background:rgba(240,160,32,.08)}
  .tab-badge.bad{color:#fff;border-color:var(--alert);background:var(--alert);animation:pulse 1.2s infinite}
  .view[hidden]{display:none}
  #livealert{top:80px}
  #sysStatus.warn{color:var(--warn);border-color:rgba(240,160,32,.45);background:rgba(240,160,32,.08)}
  @media(max-width:680px){.tab{padding:10px 12px;gap:6px;flex-direction:column;align-items:flex-start}.tab-txt{font-size:14.5px;white-space:nowrap}.tab-txt small{display:none}.tab svg{display:none}.tab-badge{margin-left:0;font-size:10.5px;padding:2px 7px}#livealert{top:84px}}
  /* ====== 银行 / 支付宝 面板 ====== */
  .bstat{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
  #bstat{display:flex;gap:8px;flex-wrap:wrap}
  .pill{font-family:var(--mono);font-size:12px;font-weight:600;padding:5px 11px;border-radius:999px;border:1px solid var(--line);color:var(--faint);display:inline-flex;align-items:center;gap:7px;white-space:nowrap}
  .pill i{width:7px;height:7px;border-radius:50%;background:currentColor}
  .pill.ok{color:var(--resume);border-color:rgba(22,199,132,.35);background:rgba(22,199,132,.06)}
  .pill.warn{color:var(--warn);border-color:rgba(240,160,32,.45);background:rgba(240,160,32,.08)}
  .pill.bad{color:#ff8a8f;border-color:rgba(234,57,67,.5);background:rgba(234,57,67,.1)}
  #bsearch{margin-left:auto;background:var(--card);border:1px solid var(--line);border-radius:7px;color:var(--txt);padding:7px 11px;font-size:13px;font-family:var(--sans);width:170px;outline:none}
  #bsearch:focus{border-color:var(--accent)}
  .focusgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px;margin-bottom:14px}
  .focusgrid:empty{display:none}
  .fcard{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 15px;position:relative}
  .fcard.warn{border-color:rgba(240,160,32,.5)}
  .fcard.bad{border-color:rgba(234,57,67,.6)}
  .fcard .dot{width:8px;height:8px;border-radius:50%;position:absolute;top:15px;right:15px}
  .fcard.warn .dot{background:var(--warn);box-shadow:0 0 0 3px rgba(240,160,32,.15),0 0 10px var(--warn)}
  .fcard.bad .dot{background:var(--alert);box-shadow:0 0 0 3px rgba(234,57,67,.15),0 0 10px var(--alert);animation:pulse 1s infinite}
  .fcard.warn .cc-status{color:var(--warn)}
  .fcard.bad .cc-status{color:var(--alert)}
  .fcard .cc-meta{word-break:normal;line-height:1.6}
  .pboc-line{font-size:12.5px;color:var(--sub);margin:0 2px 16px;line-height:1.6}
  .pboc-line:empty{display:none}
  .pboc-line b{color:var(--txt);font-family:var(--mono);font-weight:600}
  .bgroup{margin-bottom:13px}
  .bgroup-h{font-size:12px;color:var(--sub);font-weight:600;margin:0 0 7px 2px;display:flex;gap:8px;align-items:baseline}
  .bgroup-h span{font-family:var(--mono);font-weight:400;color:var(--faint);font-size:11px}
  .btiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(122px,1fr));gap:6px}
  .btile{display:flex;align-items:center;gap:8px;background:var(--card);border:1px solid var(--line);border-radius:7px;padding:8px 10px;font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden;cursor:default}
  a.btile{cursor:pointer;text-decoration:none;color:inherit;transition:border-color .12s}
  a.btile:hover{border-color:var(--accent)}
  .btile i{width:7px;height:7px;border-radius:50%;background:var(--resume);flex:none}
  .btile span{overflow:hidden;text-overflow:ellipsis}
  .btile.warn{border-color:rgba(240,160,32,.5);background:rgba(240,160,32,.08);color:#f5c26b}
  .btile.warn i{background:var(--warn)}
  .btile.bad{border-color:rgba(234,57,67,.55);background:rgba(234,57,67,.1);color:#ff8a8f}
  .btile.bad i{background:var(--alert);animation:pulse 1s infinite}
  .btile.off{color:var(--faint);border-style:dashed}
  .btile.off i{background:var(--faint)}
  .btile.hide{display:none}
  .btile.idle i{background:var(--faint)}
  /* 通道侦测项目：一家供应商一行 */
  .chbox{border:1px solid var(--line);border-radius:10px;padding:2px 12px}
  .chrow{display:flex;align-items:flex-start;gap:10px;padding:8px 0;border-top:1px solid var(--line)}
  .chrow:first-child{border-top:none}
  .chprov{width:96px;flex:none;font-size:13px;font-weight:700;padding-top:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .chprov span{font-family:var(--mono);font-weight:400;color:var(--faint);font-size:11px;margin-left:6px}
  .chitems{flex:1;min-width:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:6px}
  .chrow.wide .chitems{grid-template-columns:repeat(auto-fill,minmax(236px,1fr))}
  .chitems .btile{white-space:normal;line-height:1.35}
  .btile small.mid{display:inline-block;max-width:100%;font-family:var(--mono);font-size:11.5px;font-weight:400;color:var(--sub);overflow-wrap:anywhere}
  @media(max-width:680px){.chbox{padding:2px 10px}.chprov{width:60px;font-size:12.5px}.chprov span{display:none}.chitems,.chrow.wide .chitems{grid-template-columns:repeat(auto-fill,minmax(150px,1fr))}}
  .src{font-size:10.5px;font-family:var(--mono);color:var(--sub);border:1px solid var(--line2);border-radius:4px;padding:1px 6px}
  .tl-empty{padding:16px 0;text-align:center;color:var(--sub);font-size:13px;border-top:1px solid var(--line)}
  @media(max-width:680px){#bsearch{margin-left:0;width:100%}.btiles{grid-template-columns:repeat(auto-fill,minmax(104px,1fr))}}
  .banner.has-warn{background:rgba(240,160,32,.09);border-color:rgba(240,160,32,.4);color:#f5c26b}
  .banner.has-warn::before{background:var(--warn);box-shadow:0 0 8px var(--warn)}
  .filters.orgrow button.active{background:var(--accent);color:#04101d;border-color:var(--accent)}
  .ex-ali{background:#1677ff;color:#fff}
  .ex-wx{background:#07c160;color:#04130a}
  .ex-ysf{background:#e0413a;color:#fff}
  .ex-bank{background:#e9eef4;color:#0e141c}
  .b-soon{background:rgba(240,160,32,.15);color:#f5c26b}
  .card.lvl-soon{border-left-color:var(--warn)}
  .scope{font-size:12px;color:var(--sub);margin-top:5px}
  .tl{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px 6px;overflow:hidden}
  .tl-axis{position:relative;height:20px;margin-left:92px;font-family:var(--mono);font-size:10.5px;color:var(--faint)}
  .tl-axis span{position:absolute;top:0;transform:translateX(-50%);white-space:nowrap}
  .tl-axis span.day{color:var(--sub);font-weight:600}
  .tl-axis span:first-child{transform:none}
  .tl-axis span:last-child{transform:translateX(-100%)}
  .tl-body{position:relative}
  .tl-row{display:flex;align-items:center;height:32px;border-top:1px solid var(--line)}
  .tl-name{width:92px;flex:none;font-size:12.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding-right:8px}
  .tl-track{position:relative;flex:1;height:100%;background-image:linear-gradient(to right,var(--line) 1px,transparent 1px);background-size:12.5% 100%}
  .tl-track::after{content:"";position:absolute;left:50%;top:0;bottom:0;width:1px;background:var(--line2)}
  .tl-bar{position:absolute;top:8px;height:16px;border-radius:4px;min-width:5px;cursor:default}
  .tl-bar.now{background:var(--alert);box-shadow:0 0 10px rgba(234,57,67,.6)}
  .tl-bar.soon{background:var(--warn)}
  .tl-bar.later{background:rgba(61,155,255,.75)}
  .tl-bar.done{background:var(--faint);opacity:.6}
  .tl-bar.partial{background:repeating-linear-gradient(45deg,rgba(240,160,32,.9) 0 5px,rgba(240,160,32,.45) 5px 10px);box-shadow:none;opacity:1}
  .tl-bar.partial.done{opacity:.4}
  .tl-now{position:absolute;top:0;bottom:0;width:0;border-left:2px solid var(--txt);z-index:2;pointer-events:none}
  .tl-now::before{content:"现在";position:absolute;top:-19px;left:-2px;transform:translateX(-50%);font-family:var(--mono);font-size:10px;font-weight:700;color:var(--ink);background:var(--txt);padding:0 5px;border-radius:3px;white-space:nowrap}
  .tl-legend{display:flex;gap:14px;flex-wrap:wrap;font-size:11.5px;color:var(--sub);padding:9px 0 6px;border-top:1px solid var(--line)}
  .tl-legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}
  @media(max-width:680px){.tl{padding:12px 11px 6px}.tl-axis{margin-left:70px}.tl-name{width:70px;font-size:12px}.tl-axis span.minor{display:none}}
</style>
</head>
<body>
<header>
  <div class="brand">
    <h1><svg width="26" height="26" viewBox="0 0 24 24" style="vertical-align:-5px;margin-right:9px"><rect x="4" y="8" width="16" height="11" rx="3.5" fill="#3b82f6"/><circle cx="9.5" cy="13" r="1.7" fill="#fff"/><circle cx="14.5" cy="13" r="1.7" fill="#fff"/><path d="M12 4v4" stroke="#3b82f6" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="3.4" r="1.9" fill="#22c55e"/><rect x="9.5" y="16" width="5" height="1.6" rx="0.8" fill="#fff" opacity=".55"/></svg>监控台</h1>
    <p>虚拟币 · 网银/支付宝 · 银行 · 通道状态与维护公告</p>
  </div>
  <div class="head-right">
    <span id="sysStatus">连接中…</span>
    <a class="refresh" href="#" onclick="location.reload();return false;">刷新页面</a>
  </div>
</header>
<nav class="tabs" id="tabs" role="tablist" aria-label="监控类别">
  <button class="tab active" data-view="crypto" role="tab" aria-selected="true">
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#16c784" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M9.5 8h4a2 2 0 0 1 0 4h-4zm0 4h4.5a2 2 0 0 1 0 4H9.5zM9.5 8v8M11 6v2m2-2v2m-2 8v2m2-2v2"/></svg>
    <span class="tab-txt">虚拟币<small>链况 · 汇率 · 交易所公告</small></span>
    <span class="tab-badge" id="badge-crypto">检测中…</span>
  </button>
  <button class="tab" data-view="alipay" role="tab" aria-selected="false">
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#1677ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3 10h18M7 15h4"/></svg>
    <span class="tab-txt">网银/支付宝<small>通道项目 · 网关状态 · 维护公告</small></span>
    <span class="tab-badge" id="badge-alipay">检测中…</span>
  </button>
  <button class="tab" data-view="bank" role="tab" aria-selected="false">
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#3d9bff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10 12 4l9 6M5 10v8m4.7-8v8m4.6-8v8M19 10v8M3 20h18"/></svg>
    <span class="tab-txt">银行<small>通道状态 · 维护时间表</small></span>
    <span class="tab-badge" id="badge-bank">—</span>
  </button>
</nav>
<div class="view" id="view-crypto">
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
      <div class="ub-top">OKX 场外 · USDT / CNY<span class="ub-tag">最优 10 档中位价 · 快照 __UPDATED__</span></div>
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
  公告更新时间：__UPDATED__（北京时间，公告时间也都是北京时间）｜ 来源（官方接口）：__CXSRC__ · 每 5 分钟由 GitHub 自动更新<br>
  链实时状态 &amp; 汇率：网页内每 15~60 秒自动刷新（TronGrid / PublicNode / Toncenter / CoinGecko，每条链另有备用节点）<br>
  仅显示近一年内、涉及 TRON/BSC/ETH/TON/SOL 或交易所系统维护的公告 ｜ 点卡片可跳转官方原文
  __CXSKIP__
</footer>
</div><!-- /view-crypto -->
<div class="view" id="view-bank" hidden>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--accent)"></span><h2>银行通道状态</h2><span class="sub">后台启用的 <span id="banktotal">—</span> 家 · 依维护公告的时间段判定</span></div>
    <span class="sec-meta">公告抓取 <b id="bankupd">—</b></span>
  </div>
  <div class="bstat">
    <span id="bstat"></span>
    <input id="bsearch" type="search" placeholder="搜索银行…" autocomplete="off">
  </div>
  <div class="focusgrid" id="bankfocus"></div>
  <div class="pboc-line" id="pbocline"></div>
  <div id="bankgroups"></div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--warn)"></span><h2>维护时间表</h2><span class="sub">今天 + 明天 · 北京时间</span></div>
  </div>
  <div class="tl">
    <div class="tl-axis" id="tlaxis"></div>
    <div class="tl-body" id="tlbody"></div>
    <div class="tl-legend">
      <span><i style="background:var(--alert)"></i>维护中 · 不可使用</span>
      <span><i style="background:var(--warn)"></i>24 小时内</span>
      <span><i style="background:rgba(61,155,255,.75)"></i>之后</span>
      <span><i style="background:var(--faint)"></i>已结束</span>
      <span><i style="background:repeating-linear-gradient(45deg,rgba(240,160,32,.9) 0 3px,rgba(240,160,32,.45) 3px 6px)"></i>银行官方公告 · 部分服务可能受影响</span>
    </div>
  </div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--alert)"></span><h2>银行维护公告</h2><span class="sub">只收维护 / 暂停 / 不可使用类 · 仅后台启用的银行</span></div>
  </div>
  <div class="banner" id="bankbanner"></div>
  <div class="filters orgrow" id="orgFilters">
    <span class="flabel">按类别</span>
    <button class="active" data-g="all">全部</button>
  </div>
  <div class="filters" id="stFilters">
    <span class="flabel">按状态</span>
    <button class="active" data-s="all">全部</button>
    <button data-s="now">维护中</button>
    <button data-s="soon">即将维护</button>
    <button data-s="done">已结束</button>
  </div>
  <div class="list" id="banklist"></div>
</div>
<footer>
  <span id="banksrc"></span><br>
  通道状态由公告里的维护时间段推算：进入时间段显示「维护中」，24 小时内显示「即将维护」<br>
  黄色的「官方公告」是银行自己官网的公告（目前接了中国银行、招商、中信、建设四家），讲的是部分服务可能受影响，通道未必不可用<br>
  其余银行只有第三方支付机构转发的通知，可能不完整；没有公告不代表银行一定正常
</footer>
</div><!-- /view-bank -->
<div class="view" id="view-alipay" hidden>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:#1677ff"></span><h2>支付宝网关实时状态</h2><span class="sub">浏览器直连检测 · 60s 自动刷新</span></div>
    <span class="sec-meta">更新 <b id="aliupd">—</b> · <a href="#" id="alireload">刷新</a></span>
  </div>
  <div class="chaingrid c4" id="aligrid"></div>
  <div class="pboc-line" style="margin-top:10px">只代表从这台设备连得上支付宝网关，不代表每一笔支付都会成功</div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:#1677ff"></span><h2>通道侦测项目</h2><span class="sub">按供应商分行 · 鼠标停在格子上看完整名称</span></div>
    <span class="sec-meta">尚未接入侦测来源</span>
  </div>
  <div class="filters orgrow" id="chanFilters"></div>
  <div class="chbox" id="changroups"></div>
  <div class="pboc-line" style="margin-top:10px">目前只列出名单，灰点表示还没有侦测来源，不代表通道正常或异常</div>
</div>
<div class="section">
  <div class="sec-head">
    <div class="sec-title"><span class="bar" style="background:var(--alert)"></span><h2>支付宝维护公告</h2><span class="sub">只收维护 / 暂停 / 异常类 · 近一年</span></div>
    <span class="sec-meta">公告抓取 <b id="alifetch">—</b></span>
  </div>
  <div class="banner" id="alibanner"></div>
  <div class="list" id="alilist"></div>
</div>
<footer>
  <span id="alisrc"></span><br>
  支付宝很少公开发布维护公告，这里没有公告不代表支付宝一定正常，请以上方的实时状态为准
</footer>
</div><!-- /view-alipay -->
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
  // 链和节点的名单由脚本里的 $ChainDefs 生成（跟 Telegram 的链异常检测共用一份）
  var CHAINS=__CHAINS__;
  var last={},failN={};
  // 页面上的「更新 xx:xx:xx」一律显示北京时间，不跟着看网页的那台设备的时区走
  function bjClock(){var d=new Date(Date.now()+8*3600000);function p(n){return (n<10?'0':'')+n;}return p(d.getUTCHours())+':'+p(d.getUTCMinutes())+':'+p(d.getUTCSeconds());}
  // 8 秒没回应就放弃：节点卡住不回的话，要能轮到备用节点
  function tfetch(u,o){var c=new AbortController(),to=setTimeout(function(){c.abort();},8000);o=o||{};o.signal=c.signal;return fetch(u,o).then(function(r){clearTimeout(to);return r;},function(e){clearTimeout(to);throw e;});}
  function jrpc(u,m,p){return tfetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',method:m,params:p||[],id:1})}).then(function(r){return r.json();});}
  function fetchNode(nd){
    if(nd.t==='tron'){return tfetch(nd.u,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(function(r){return r.json();}).then(function(j){return {h:j.block_header.raw_data.number,ts:j.block_header.raw_data.timestamp};});}
    if(nd.t==='evm'){return jrpc(nd.u,'eth_getBlockByNumber',['latest',false]).then(function(j){return {h:parseInt(j.result.number,16),ts:parseInt(j.result.timestamp,16)*1000};});}
    // Solana / TON 都看最新区块的出块时间：只问节点健不健康的话，整条链一起停摆时看不出来
    if(nd.t==='sol'){return jrpc(nd.u,'getSlot',[{commitment:'confirmed'}]).then(function(s){
      return jrpc(nd.u,'getBlockTime',[s.result]).then(function(b){
        if(b.result) return {h:s.result,ts:b.result*1000};
        // 偶尔取不到出块时间：退回用节点健康状态判断
        return jrpc(nd.u,'getHealth').then(function(a){return {h:s.result,health:a.result||(a.error&&a.error.message)||'?'};});
      });
    });}
    if(nd.t==='ton'){return tfetch(nd.u).then(function(r){return r.json();}).then(function(j){return {h:j.last.seqno,ts:j.last.gen_utime*1000};});}
    if(nd.t==='tonapi'){return tfetch(nd.u).then(function(r){return r.json();}).then(function(j){return {h:j.seqno,ts:j.gen_utime*1000};});}
    return Promise.reject(new Error('unknown node type'));
  }
  // 按顺序试每个节点：有一个回报正常就用它；都不正常时用第一个拿得到数据的结果；全部连不上才算读取失败
  function fetchChain(c){
    var i=0,best=null;
    function next(){
      if(i>=c.nodes.length) return best?Promise.resolve(best):Promise.reject(new Error('all nodes failed'));
      var nd=c.nodes[i++];
      return fetchNode(nd).then(function(d){
        if(judge(c,d).cls==='ok') return d;
        if(!best) best=d;
        return next();
      },function(){ return next(); });
    }
    return next();
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
    return {cls:'bad',status:'读取失败',meta:'取不到区块时间'};
  }
  function renderCard(c,res){
    var el=document.getElementById('cc-'+c.k); if(!el)return;
    el.className='chaincard '+res.cls;
    el.querySelector('.cc-status').textContent=res.status;
    el.querySelector('.cc-meta').textContent=res.meta;
  }
  // ====== 异常视觉提醒：横幅 + 状态 + 标题闪烁 ======
  var prevCls={}, flashTimer=null;
  function flashTitle(msg){ if(flashTimer)return; var on=false; flashTimer=setInterval(function(){document.title=on?'监控台':('🔴 '+msg);on=!on;},800); }
  function stopFlash(){ if(flashTimer){clearInterval(flashTimer);flashTimer=null;document.title='监控台';} }
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
      return fetchChain(c).then(function(d){failN[c.k]=0;var res=judge(c,d);last[c.k]=d.h;return {c:c,res:res};})
      // 节点偶尔会限流或没回应：第一次读不到先标黄重试，连续两次才算异常，避免误报
      .catch(function(e){failN[c.k]=(failN[c.k]||0)+1;return {c:c,res:failN[c.k]>=2?{cls:'bad',status:'读取失败',meta:'节点连续无响应'}:{cls:'warn',status:'读取失败 · 重试中',meta:'节点暂时无响应'}};});
    })).then(function(arr){
      var newlyBad=[],badNow=[];
      arr.forEach(function(x){
        renderCard(x.c,x.res);
        if(x.res.cls==='bad'){ badNow.push(x.c.n); if(prevCls[x.c.k]!=='bad')newlyBad.push(x.c.n); }
        prevCls[x.c.k]=x.res.cls;
      });
      handleAlerts(newlyBad,badNow);
      var u=document.getElementById('upd'); if(u)u.textContent=bjClock();
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
      var u=document.getElementById('rateupd'); if(u)u.textContent=bjClock();
    }).catch(function(e){ var u=document.getElementById('rateupd'); if(u)u.textContent='读取失败(稍后重试)'; });
  }
  updateRates();
  setInterval(updateRates,60000);
  // 公告数据每 5 分钟随页面自动刷新（重新载入 GitHub 最新生成的 index.html）
  setTimeout(function(){ location.reload(); }, 300000);
</script>
<script>
(function(){
  // ====== 视图切换：网址 #crypto / #alipay / #bank，自动刷新后停留在原分页 ======
  var VIEWS=['crypto','alipay','bank'],VNAME={crypto:'虚拟币',alipay:'网银/支付宝',bank:'银行'};
  function show(v){
    if(VIEWS.indexOf(v)<0) v='crypto';
    VIEWS.forEach(function(k){
      document.getElementById('view-'+k).hidden=(k!==v);
      var t=document.querySelector('.tab[data-view="'+k+'"]');
      t.classList.toggle('active',k===v);
      t.setAttribute('aria-selected',k===v?'true':'false');
    });
    try{localStorage.setItem('monitorView',v);}catch(e){}
    if(location.hash!=='#'+v){ try{history.replaceState(null,'','#'+v);}catch(e){} }
    if(v==='bank') renderBank();
  }
  document.querySelectorAll('#tabs .tab').forEach(function(t){
    t.addEventListener('click',function(){ show(t.getAttribute('data-view')); window.scrollTo(0,0); });
  });
  window.addEventListener('hashchange',function(){ show(location.hash.slice(1)); });

  // ====== 分页徽章 + 右上角总状态（不用切换也能看到其他分页有没有事） ======
  var state={crypto:{cls:''},bank:{cls:''},alipay:{cls:''}};
  function setBadge(k,cls,txt){
    state[k]={cls:cls,txt:txt};
    var b=document.getElementById('badge-'+k); b.className='tab-badge '+cls; b.textContent=txt;
    var ss=document.getElementById('sysStatus'); if(!ss)return;
    var bad=[],warn=[],okN=0;
    VIEWS.forEach(function(v){
      if(state[v].cls==='bad')bad.push(VNAME[v]+' '+state[v].txt);
      else if(state[v].cls==='warn')warn.push(VNAME[v]+' '+state[v].txt);
      else if(state[v].cls==='ok')okN++;
    });
    if(bad.length){ss.className='bad';ss.textContent='▲ '+bad.join(' · ');}
    else if(warn.length){ss.className='warn';ss.textContent='● '+warn.join(' · ');}
    else if(okN===VIEWS.length){ss.className='ok';ss.textContent='● 全部正常';}
  }
  var CXBAD=__CXBAD__;   // 这次有几家交易所的公告没抓成功
  var origHandle=window.handleAlerts;
  window.handleAlerts=function(newlyBad,badNow){
    origHandle(newlyBad,badNow);
    if(badNow.length) setBadge('crypto','bad',badNow.length+' 链异常');
    else if(CXBAD) setBadge('crypto','warn','公告抓取异常');
    else setBadge('crypto','ok','正常');
  };

  // ====== 数据：名单来自 banks.json，公告来自抓取脚本生成的 bank-data.json ======
  var CFG=__BANK_CFG__;
  var DATA=__BANK_DATA__;
  var HOUR=3600000,DAY=86400000,TZ=8*HOUR;   // 一律按北京时间显示
  var BANKS=[];
  CFG.groups.forEach(function(g){ g.banks.forEach(function(b){ BANKS.push({s:b.s,n:b.n,g:g.id}); }); });
  var EVENTS=DATA.events.slice();
  var PBOC='央行支付系统';
  (DATA.pboc.windows||[]).forEach(function(w){
    EVENTS.push({bank:PBOC,g:'pboc',s:w.s,e:w.e,scope:'全部银行 · 跨行转账（小额支付、网上支付跨行清算）',title:'人民银行支付系统维护窗口',url:DATA.pboc.url,src:'清算总中心'});
  });

  function p2(n){return (n<10?'0':'')+n;}
  function dayStart(ts){return Math.floor((ts+TZ)/DAY)*DAY-TZ;}
  function hm(ts){var d=new Date(ts+TZ);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());}
  function md(ts){var d=new Date(ts+TZ);return p2(d.getUTCMonth()+1)+'-'+p2(d.getUTCDate());}
  function ymd(ts){var d=new Date(ts+TZ);return d.getUTCFullYear()+'-'+md(ts);}
  function dayLabel(ts){
    var d=Math.round((dayStart(ts)-dayStart(Date.now()))/DAY);
    return d===0?'今天':d===1?'明天':d===2?'后天':d===-1?'昨天':md(ts);
  }
  function win(e){var a=dayLabel(e.s),b=dayLabel(e.e);return a+' '+hm(e.s)+' – '+(a===b?'':b+' ')+hm(e.e);}
  function st(e,now){ if(now<e.s)return (e.s-now<=24*HOUR)?'soon':'later'; return now<=e.e?'now':'done'; }
  function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
  function byStart(a,b){return a.s-b.s;}
  var ST_TXT={now:'维护中',soon:'即将维护',later:'已排程',done:'已结束'},ST_LV={now:'alert',soon:'soon',later:'upgrade',done:'resume'};
  // 银行官网公告（sev=partial）：只是部分服务可能受影响，不等于通道不可用，所以一律用黄色、不标红
  var PT_TXT={now:'官方公告 · 进行中',soon:'官方公告 · 即将开始',later:'官方公告 · 已排程',done:'官方公告 · 已结束'},PT_LV={now:'soon',soon:'soon',later:'upgrade',done:'resume'};
  function isPart(e){return e.sev==='partial';}
  function eventCard(e,chip){
    var lv=(isPart(e)?PT_LV:ST_LV)[e.st],tx=(isPart(e)?PT_TXT:ST_TXT)[e.st];
    return '<a class="card lvl-'+lv+'" href="'+esc(e.url)+'" target="_blank" rel="noopener"><div class="row1"><span class="ex '+chip+'">'+e.bank+'</span><span class="badge b-'+lv+'">'+tx+'</span><span class="src">'+esc(e.src)+'</span><span class="time">'+win(e)+'</span></div><div class="title">'+esc(e.title)+'</div><div class="scope">影响范围：'+esc(e.scope)+'</div></a>';
  }
  function srcLine(names){
    return '来源：'+DATA.sources.filter(function(s){return names.indexOf(s.name)>=0;}).map(function(s){return s.name+(!s.ok?' ✗ 抓取失败'+(s.err?'（'+s.err+'）':''):(s.warn?' ⚠ '+s.warn:' ✓'));}).join(' · ');
  }
  // 有问题的公告来源：连不上，或连得上但内容读不出来（warn，多半是网页改版）；抓取程序整个没跑成功时也算
  function srcBad(names){
    if(!DATA.updated) return ['抓取程序没有运行'];
    return DATA.sources.filter(function(s){return names.indexOf(s.name)>=0&&(!s.ok||s.warn);}).map(function(s){return s.name;});
  }
  function skippedN(isAli){ return (DATA.skipped||[]).filter(function(t){return (t.indexOf('支付宝：')===0)===isAli;}).length; }

  // ====== 银行 ======
  function status(name){
    var ev=EVENTS.filter(function(e){return e.bank===name;});
    var hard=ev.filter(function(e){return !isPart(e);}),soft=ev.filter(isPart);
    function pick(list,s){return list.filter(function(e){return e.st===s;}).sort(byStart)[0];}
    var cur=pick(hard,'now'),nxt=pick(hard,'soon');
    if(cur) return {cls:'bad',kind:'stop',txt:'维护中 · 不可使用',meta:'预计 '+dayLabel(cur.e)+' '+hm(cur.e)+' 结束 ｜ '+cur.scope};
    if(nxt) return {cls:'warn',kind:'soon',txt:'即将维护',meta:win(nxt)+' ｜ '+nxt.scope};
    // 银行官网公告：部分服务可能受影响，只标黄，不算「维护中」
    var pc=pick(soft,'now'),pn=pick(soft,'soon');
    if(pc) return {cls:'warn',kind:'part',txt:'官方公告 · 部分服务维护中',meta:'预计 '+dayLabel(pc.e)+' '+hm(pc.e)+' 结束 ｜ '+pc.scope};
    if(pn) return {cls:'warn',kind:'part',txt:'官方公告 · 即将维护',meta:win(pn)+' ｜ '+pn.scope};
    var ltr=pick(ev,'later');
    if(ltr) return {cls:'ok',kind:'ok',txt:'正常',meta:'下次维护 '+win(ltr)};
    return {cls:'ok',kind:'ok',txt:'正常',meta:'无维护公告'};
  }
  var gF='all',sF='all',q='';
  function renderBank(){
    var now=Date.now();
    EVENTS.forEach(function(e){e.st=st(e,now);});
    document.getElementById('banktotal').textContent=BANKS.length;
    // 需要注意的银行（大卡片）+ 全部银行（小格）
    var cnt={stop:0,soon:0,part:0,ok:0},focus='',groups='';
    var ps=status(PBOC);
    if(ps.kind!=='ok') focus+='<div class="fcard '+ps.cls+'"><div class="dot"></div><div class="cc-name">'+PBOC+'<span>影响全部银行</span></div><div class="cc-status">'+ps.txt+'</div><div class="cc-meta">'+esc(ps.meta)+'</div></div>';
    CFG.groups.forEach(function(g){
      var tiles='';
      g.banks.forEach(function(b){
        var s=status(b.s); cnt[s.kind]++;
        if(s.kind!=='ok') focus+='<div class="fcard '+s.cls+'"><div class="dot"></div><div class="cc-name">'+b.s+'<span>'+g.name+'</span></div><div class="cc-status">'+s.txt+'</div><div class="cc-meta">'+esc(s.meta)+'</div></div>';
        var hide=q&&(b.s+b.n).indexOf(q)<0;
        // 有官网网址（banks.json 的 u）的银行可以点开官网，没填的维持不能点
        var cls='btile '+(s.kind==='ok'?'':s.cls)+(hide?' hide':''),tip=esc(b.n+' ｜ '+s.txt+' ｜ '+s.meta);
        tiles+=b.u?('<a class="'+cls+'" href="'+esc(b.u)+'" target="_blank" rel="noopener" title="'+tip+' ｜ 点击打开官网"><i></i><span>'+b.s+'</span></a>')
                  :('<div class="'+cls+'" title="'+tip+'"><i></i><span>'+b.s+'</span></div>');
      });
      groups+='<div class="bgroup"><div class="bgroup-h">'+g.name+'<span>'+g.banks.length+' 家</span></div><div class="btiles">'+tiles+'</div></div>';
    });
    document.getElementById('bankfocus').innerHTML=focus;
    document.getElementById('bankgroups').innerHTML=groups;
    document.getElementById('bstat').innerHTML=
      '<span class="pill'+(cnt.stop?' bad':'')+'"><i></i>维护中 '+cnt.stop+'</span>'+
      '<span class="pill'+(cnt.soon?' warn':'')+'"><i></i>即将维护 '+cnt.soon+'</span>'+
      (cnt.part?'<span class="pill warn"><i></i>官方公告 '+cnt.part+'</span>':'')+
      '<span class="pill ok"><i></i>正常 '+cnt.ok+'</span>';
    // 央行窗口提示
    var pn=EVENTS.filter(function(e){return e.g==='pboc'&&e.e>now;}).sort(byStart)[0];
    document.getElementById('pbocline').innerHTML=pn?('下次央行支付系统维护：<b>'+md(pn.s)+' '+hm(pn.s)+' – '+hm(pn.e)+'</b>，期间全部银行的跨行转账暂停'):'';
    // 时间表：今天 00:00 起 48 小时，一家银行一行
    var A=dayStart(now),SPAN=48*HOUR,ax='';
    for(var h=0;h<=48;h+=6){
      var lab=(h===0)?'今天 00':(h===24)?'明天 00':(h===48)?'24':p2(h%24);
      ax+='<span class="'+((h%24===0)?'day':(h%12===0?'':'minor'))+'" style="left:'+(h/48*100)+'%">'+lab+'</span>';
    }
    document.getElementById('tlaxis').innerHTML=ax;
    var inRange=EVENTS.filter(function(e){return e.e>A&&e.s<A+SPAN;}).sort(byStart),names=[],rows='';
    inRange.forEach(function(e){if(names.indexOf(e.bank)<0)names.push(e.bank);});
    names.forEach(function(nm){
      var bars='';
      inRange.filter(function(e){return e.bank===nm;}).forEach(function(e){
        var l=Math.max(0,(e.s-A)/SPAN*100),r=Math.min(100,(e.e-A)/SPAN*100);
        bars+='<div class="tl-bar '+e.st+(isPart(e)?' partial':'')+'" style="left:'+l+'%;width:'+(r-l)+'%" title="'+esc(nm+' '+win(e)+' ｜ '+e.scope)+'"></div>';
      });
      rows+='<div class="tl-row"><div class="tl-name">'+nm+'</div><div class="tl-track">'+bars+'</div></div>';
    });
    if(!names.length) rows='<div class="tl-empty">今天和明天没有维护公告</div>';
    rows+='<div class="tl-now" id="tlnow"></div>';
    var body=document.getElementById('tlbody'); body.innerHTML=rows;
    var nm1=body.querySelector('.tl-name'),nameW=(nm1&&nm1.offsetWidth)||92;
    document.getElementById('tlnow').style.left='calc('+nameW+'px + (100% - '+nameW+'px) * '+((now-A)/SPAN)+')';
    // 横幅 + 徽章
    var bn=document.getElementById('bankbanner'),soonN=cnt.soon+(ps.kind==='soon'?1:0);
    if(ps.kind==='stop'){bn.className='banner has-alert';bn.textContent='央行支付系统维护中，全部银行跨行转账暂停'+(cnt.stop?('；另有 '+cnt.stop+' 家银行维护中'):'');setBadge('bank','bad','央行维护中');}
    else if(cnt.stop){bn.className='banner has-alert';bn.textContent='当前 '+cnt.stop+' 家银行维护中、不可使用'+(soonN?('，24 小时内还有 '+soonN+' 项即将维护'):'')+'，请留意相关通道的出入款';setBadge('bank','bad',cnt.stop+' 家维护中');}
    else if(soonN){bn.className='banner has-warn';bn.textContent='24 小时内有 '+soonN+' 项即将维护，当前通道全部正常';setBadge('bank','warn',soonN+' 项即将维护');}
    else if(cnt.part){bn.className='banner has-warn';bn.textContent=cnt.part+' 家银行有官方维护公告，部分服务可能受影响，通道未必不可用';setBadge('bank','warn',cnt.part+' 家官方公告');}
    else if(srcBad(['易宝支付','快钱']).length){bn.className='banner has-warn';bn.textContent='公告来源异常（'+srcBad(['易宝支付','快钱']).join('、')+'），目前显示的状态可能不准';setBadge('bank','warn','来源异常');}
    else{bn.className='banner no-alert';bn.textContent='当前无维护，24 小时内也没有计划维护';setBadge('bank','ok','正常');}
    // 公告列表
    var order={now:0,soon:1,later:2,done:3};
    var list=EVENTS.filter(function(e){
      var s=(e.st==='later')?'soon':e.st;
      return (gF==='all'||e.g===gF)&&(sF==='all'||s===sF);
    }).sort(function(a,b){ return (order[a.st]-order[b.st])||(a.st==='done'?b.e-a.e:a.s-b.s); });
    document.getElementById('banklist').innerHTML=list.map(function(e){return eventCard(e,'ex-bank');}).join('')||'<div class="empty">没有符合条件的公告<span>换个筛选条件试试</span></div>';
    document.getElementById('bankupd').textContent=md(DATA.updated)+' '+hm(DATA.updated);
    var bsrc=DATA.sources.map(function(s){return s.name;}).filter(function(n){return n!=='支付宝开放平台';});
    document.getElementById('banksrc').textContent=srcLine(bsrc)+' · 人民银行清算总中心（年度安排）｜已过滤非维护类公告 '+skippedN(false)+' 条';
  }
  // 类别筛选按钮按 banks.json 的分组生成
  var of=document.getElementById('orgFilters');
  CFG.groups.concat([{id:'pboc',name:'央行'}]).forEach(function(g){
    var b=document.createElement('button'); b.setAttribute('data-g',g.id); b.textContent=g.name; of.appendChild(b);
  });
  function bindFilter(id,attr,set){
    document.querySelectorAll('#'+id+' button').forEach(function(b){
      b.addEventListener('click',function(){
        document.querySelectorAll('#'+id+' button').forEach(function(x){x.classList.remove('active');});
        b.classList.add('active'); set(b.getAttribute(attr)); renderBank();
      });
    });
  }
  bindFilter('orgFilters','data-g',function(v){gF=v;});
  bindFilter('stFilters','data-s',function(v){sF=v;});
  document.getElementById('bsearch').addEventListener('input',function(ev){ q=ev.target.value.trim(); renderBank(); });

  // ====== 支付宝：网关由浏览器直连检测，公告来自抓取脚本 ======
  var ALI=CFG.alipay,AD=DATA.alipay||{events:[],notices:[]},gw=null;
  function checkGateways(){
    Promise.all(ALI.gateways.map(function(g){
      var t=performance.now(),c=new AbortController(),to=setTimeout(function(){c.abort();},10000);
      return fetch(g.u+(g.u.indexOf('?')<0?'?':'&')+'_='+Date.now(),{mode:'no-cors',cache:'no-store',signal:c.signal})
        .then(function(){clearTimeout(to);var ms=Math.round(performance.now()-t);return {cls:ms>=6000?'warn':'ok',status:ms>=6000?'响应偏慢':'连线正常',meta:'响应 '+ms+' ms'};})
        .catch(function(){clearTimeout(to);return {cls:'bad',status:'连不上',meta:'10 秒内无响应'};});
    })).then(function(arr){
      gw=arr; renderAlipay();
      document.getElementById('aliupd').textContent=bjClock();
    });
  }
  function renderAlipay(){
    var now=Date.now(),ev=(AD.events||[]).slice(),nt=(AD.notices||[]).slice();
    ev.forEach(function(e){e.st=st(e,now);});
    document.getElementById('aligrid').className='chaingrid c'+Math.min(Math.max(ALI.gateways.length,1),4);
    document.getElementById('aligrid').innerHTML=ALI.gateways.map(function(g,i){
      var r=gw?gw[i]:{cls:'',status:'检测中…',meta:'—'};
      return '<div class="chaincard '+r.cls+'"><div class="dot"></div><div class="cc-name">'+esc(g.n)+'<span>'+esc(g.s)+'</span></div><div class="cc-status">'+r.status+'</div><div class="cc-meta">'+r.meta+'</div></div>';
    }).join('');
    var badGw=gw?gw.filter(function(r){return r.cls==='bad';}).length:0;
    var slowGw=gw?gw.filter(function(r){return r.cls==='warn';}).length:0;
    var nowN=ev.filter(function(e){return e.st==='now';}).length;
    var soonN=ev.filter(function(e){return e.st==='soon';}).length;
    var fresh=nt.filter(function(n){return now-n.pub<=3*DAY;}).length;   // 3 天内的新公告
    var bn=document.getElementById('alibanner');
    if(nowN){bn.className='banner has-alert';bn.textContent='支付宝维护中、不可使用，请留意出入款';setBadge('alipay','bad','维护中');}
    else if(badGw){bn.className='banner has-alert';bn.textContent=badGw+' 个支付宝网关连不上，请立即核实支付是否正常';setBadge('alipay','bad',badGw+' 个网关异常');}
    else if(soonN){bn.className='banner has-warn';bn.textContent='支付宝 24 小时内有计划维护';setBadge('alipay','warn','即将维护');}
    else if(fresh){bn.className='banner has-warn';bn.textContent='近 3 天有 '+fresh+' 条支付宝维护 / 异常公告';setBadge('alipay','warn',fresh+' 条新公告');}
    else if(slowGw){bn.className='banner has-warn';bn.textContent=slowGw+' 个支付宝网关响应偏慢';setBadge('alipay','warn','响应偏慢');}
    else if(srcBad(['支付宝开放平台']).length){bn.className='banner has-warn';bn.textContent='支付宝公告来源异常，公告区可能不完整'+(gw?'；网关连线正常':'');setBadge('alipay','warn','来源异常');}
    else if(gw){bn.className='banner no-alert';bn.textContent='当前无维护公告，网关连线正常';setBadge('alipay','ok','正常');}
    else{bn.className='banner no-alert';bn.textContent='当前无维护公告，网关检测中…';}
    var order={now:0,soon:1,later:2,done:3};
    var html=ev.sort(function(a,b){return (order[a.st]-order[b.st])||(a.s-b.s);}).map(function(e){return eventCard(e,'ex-ali');}).join('');
    html+=nt.map(function(n){
      var isNew=now-n.pub<=3*DAY,lv=isNew?'alert':'resume';
      return '<a class="card lvl-'+lv+'" href="'+esc(n.url)+'" target="_blank" rel="noopener"><div class="row1"><span class="ex ex-ali">支付宝</span><span class="badge b-'+lv+'">'+(isNew?'维护 / 异常':'已过去')+'</span><span class="src">'+esc(n.src)+'</span><span class="time">'+ymd(n.pub)+'</span></div><div class="title">'+esc(n.title)+'</div></a>';
    }).join('');
    document.getElementById('alilist').innerHTML=html||'<div class="empty">近一年没有维护 / 异常类公告</div>';
    document.getElementById('alifetch').textContent=md(DATA.updated)+' '+hm(DATA.updated);
    document.getElementById('alisrc').textContent=srcLine(['支付宝开放平台','易宝支付','快钱'])+'｜已过滤非维护类公告 '+skippedN(true)+' 条';
  }
  document.getElementById('alireload').addEventListener('click',function(ev){ev.preventDefault();checkGateways();});

  // ====== 通道侦测项目：名单来自 banks.json 的 channels，内部 / 外部 用按钮切换，一家供应商一行 ======
  // 目前还没有侦测来源，格子前面的状态点一律是灰色
  var chF='in'; try{chF=localStorage.getItem('monitorChan')||'in';}catch(e){}
  function renderChannels(){
    var groups=(CFG.channels&&CFG.channels.groups)||[],bt=document.getElementById('chanFilters'),box=document.getElementById('changroups');
    bt.innerHTML='';
    if(!groups.length){ box.innerHTML='<div class="tl-empty" style="border-top:none">banks.json 里还没有通道名单</div>'; return; }
    if(!groups.some(function(g){return g.id===chF;})) chF=groups[0].id;
    groups.forEach(function(g){
      var n=0; g.providers.forEach(function(p){n+=p.items.length;});
      var b=document.createElement('button'); b.textContent=g.name+' '+n; if(g.id===chF)b.className='active';
      b.addEventListener('click',function(){ chF=g.id; try{localStorage.setItem('monitorChan',chF);}catch(e){} renderChannels(); });
      bt.appendChild(b);
    });
    var html='';
    groups.filter(function(g){return g.id===chF;})[0].providers.forEach(function(p){
      var tiles='';
      // s 是去掉供应商前缀的短名，n 是完整名称（放在悬停提示里），m 是商户号（括号显示在名称后面）
      p.items.forEach(function(c){
        var tip=c.n+(c.m?'（商户号 '+c.m+'）':'')+' ｜ 尚未接入侦测';
        tiles+='<div class="btile idle" title="'+esc(tip)+'"><i></i><span>'+esc(c.s||c.n)+(c.m?'<small class="mid">（'+esc(c.m)+'）</small>':'')+'</span></div>';
      });
      html+='<div class="chrow'+(p.wide?' wide':'')+'"><div class="chprov" title="'+esc(p.p)+'">'+esc(p.p)+'<span>'+p.items.length+'</span></div><div class="chitems">'+tiles+'</div></div>';
    });
    box.innerHTML=html;
  }

  var saved=null; try{saved=localStorage.getItem('monitorView');}catch(e){}
  show(location.hash.slice(1)||saved||'crypto');
  renderBank(); renderChannels(); renderAlipay(); checkGateways();
  setInterval(function(){renderBank();checkGateways();},60000);
  window.addEventListener('resize',renderBank);
})();
</script>
</body>
</html>
'@

# ============ 银行 / 支付宝 维护公告（bank-fetch.ps1 抓取后写入 bank-data.json） ============
# 抓取失败时用空数据，网页照常生成
$bankCfgJson  = '{"groups":[],"alipay":{"gateways":[]},"pboc":{"windows":[]}}'
$bankDataJson = '{"updated":0,"sources":[],"events":[],"pboc":{"url":"","windows":[]},"alipay":{"events":[],"notices":[]},"skipped":[]}'
$bankData = $null
try {
  & (Join-Path $ScriptDir 'bank-fetch.ps1')
  $cfgText  = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'banks.json'), [System.Text.Encoding]::UTF8).Trim()
  $dataText = [System.IO.File]::ReadAllText((Join-Path $ScriptDir 'bank-data.json'), [System.Text.Encoding]::UTF8).Trim()
  $bankData = $dataText | ConvertFrom-Json
  $bankCfgJson = $cfgText; $bankDataJson = $dataText
} catch { Write-Host "    银行 / 支付宝 抓取失败: $($_.Exception.Message)" -ForegroundColor DarkYellow }

$html = $tpl.Replace('__BANNERCLASS__', $bannerClass).Replace('__BANNERTEXT__', $bannerText).Replace('__ROWS__', $rows).Replace('__OKXBUY__', $okxBuy).Replace('__OKXSELL__', $okxSell).Replace('__UPDATED__', $updated)
$html = $html.Replace('__CXSRC__', $cxSrcLine).Replace('__CXSKIP__', $cxSkipHtml).Replace('__CXBAD__', [string]($cxDown.Count + $cxPart.Count)).Replace('__CHAINS__', $chainsJson)
# JSON 直接嵌进网页；把 </ 转义，避免内容里出现 </script> 把网页截断
$html = $html.Replace('__BANK_CFG__', $bankCfgJson.Replace('</', '<\/')).Replace('__BANK_DATA__', $bankDataJson.Replace('</', '<\/'))
# 「重新抓取」链接指向本脚本的 bat 启动器

# 用 UTF-8 写出（PS5.1 的 utf8 带 BOM，配合 meta charset 无乱码）
$html | Out-File -FilePath $OutFile -Encoding utf8

Write-Host "  网页已生成：$OutFile" -ForegroundColor Green

# ============ Telegram 推送（配置了 Secrets 时；交易所公告只推近3天内、未推过、涉及 $PushChains 的 维护/暂停/升级）============
$tgToken = $env:TG_TOKEN; $tgChat = $env:TG_CHAT
if ($tgToken -and $tgChat) {
  $pushedFile = Join-Path $ScriptDir 'pushed.txt'
  $pushed = @(); if (Test-Path $pushedFile) { $pushed = @(Get-Content $pushedFile -Encoding UTF8) }
  $recent = $nowBJ.AddDays(-3)
  $toNotify = @($items | Where-Object { ($_.Level -eq 'alert' -or $_.Level -eq 'upgrade') -and $_.Time -ge $recent })
  # 交易所公告只推标题涉及 $PushChains 这些链的（目前只有 TRON / TRC20）；其他链和交易所整体维护只显示在网页上
  $toPush = @($toNotify | Where-Object { $c = @($_.Chains); @($PushChains | Where-Object { $c -contains $_ }).Count -gt 0 })
  $newCount = 0
  foreach ($n in $toPush) {
    if ($pushed -contains $n.Url) { continue }
    $emoji = if ($n.Level -eq 'alert') { "🔴" } else { "🔵" }
    $chains = if ($n.Chains) { ($n.Chains -join '/') } else { '多链' }
    $msg = "$emoji $($levelText[$n.Level]) · $($n.Exchange)`n链：$chains`n$($n.Title)`n$($n.Url)"
    if (Send-TGOk $tgToken $tgChat $msg) { $pushed += $n.Url; $newCount++; Start-Sleep -Milliseconds 400 }
  }

  # ---- 银行 / 支付宝 维护推送（自动去重）----
  # 每个维护时间段最多推这几次：
  #   一周前（离开始 7 天内）→ 前一日（24 小时内）→ 前一小时（60 分钟内，或发现时已经开始）→ 结束
  # 离开始还超过 7 天的先不推，只记录在网页上；等进入 7 天内才推第一次
  # 公告出来得晚、已经错过前面的时间点时，从当下所在的那一段开始推，不补发前面的
  $bankPush = 0
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $WeekMs   = 7 * 86400000   # 一周前
  $DayMs    = 86400000       # 前一日
  $RemindMs = 60 * 60000     # 前一小时
  $site = 'https://workschedule-netizen.github.io/crypto-monitor/'
  if ($bankData) {
    $bankEvents = @()
    # soft = 银行官网自己的公告（sev=partial）：只是部分服务可能受影响、通道未必不可用，所以措辞不同，也不推「结束」
    foreach ($ev in @($bankData.events))        { if ($ev) { $bankEvents += [pscustomobject]@{ bank = $ev.bank; s = [int64]$ev.s; e = [int64]$ev.e; scope = $ev.scope; url = $ev.url; tab = 'bank'; soft = ($ev.sev -eq 'partial'); title = [string]$ev.title } } }
    foreach ($ev in @($bankData.alipay.events)) { if ($ev) { $bankEvents += [pscustomobject]@{ bank = $ev.bank; s = [int64]$ev.s; e = [int64]$ev.e; scope = $ev.scope; url = $ev.url; tab = 'alipay'; soft = $false; title = '' } } }
    # 央行窗口是全年固定安排，一样照「一周前 / 前一日 / 前一小时」提醒
    foreach ($w in @($bankData.pboc.windows))   { if ($w)  { $bankEvents += [pscustomobject]@{ bank = '央行支付系统'; s = [int64]$w.s; e = [int64]$w.e; scope = '全部银行跨行转账'; url = $bankData.pboc.url; tab = 'bank'; soft = $false; title = '' } } }
    foreach ($ev in $bankEvents) {
      $id = "$($ev.bank)|$($ev.s)|$($ev.e)"
      $kWeek = "bank-w7|$id"; $kDay = "bank-d1|$id"; $kStart = "bank-start|$id"; $kEnd = "bank-end|$id"
      $when = "$(Fmt-BJ $ev.s) – $(Fmt-BJ $ev.e)（北京时间）"
      $left = $ev.s - $nowMs
      if ($nowMs -ge $ev.e) {
        # 已经结束：推过「前一小时 / 维护中」的才补一条结束通知
        if ((-not $ev.soft) -and ($pushed -contains $kStart) -and ($pushed -notcontains $kEnd)) {
          if (Send-TGOk $tgToken $tgChat "🟢 维护结束 · $($ev.bank)`n公告的维护时间已过（$(Fmt-BJ $ev.e) 结束），可以重新启用`n$site#$($ev.tab)") { $pushed += $kEnd; $bankPush++; Start-Sleep -Milliseconds 400 }
        }
        continue
      }
      # 现在落在哪一段：key 是这一段的去重记号，stage / line 是消息里的说法
      if ($left -le 0)             { $key = $kStart; $icon = '🔴'; $stage = '维护中';   $line = '已经开始' }
      elseif ($left -le $RemindMs) { $key = $kStart; $icon = '🔴'; $stage = '即将维护'; $line = "$([int][Math]::Ceiling($left / 60000)) 分钟后开始" }
      elseif ($left -le $DayMs)    { $key = $kDay;   $icon = '⏰'; $stage = '前一日提醒'; $line = "约 $([int][Math]::Ceiling($left / 3600000)) 小时后开始" }
      elseif ($left -le $WeekMs)   { $key = $kWeek;  $icon = '🏦'; $stage = '维护预告'; $line = "还有 $([int][Math]::Ceiling($left / 86400000)) 天" }
      else { continue }
      if ($pushed -contains $key) { continue }
      # 快开始了附网页连结，方便直接看状态；提前的预告附公告原文
      $link = if ($key -eq $kStart) { "$site#$($ev.tab)" } else { [string]$ev.url }
      $msg = if ($ev.soft) { "🟡 银行官方公告 · $($ev.bank)（$stage）`n$($ev.title)`n$line`n时间：$when`n$($ev.scope)`n这是银行自己的公告，通道未必不可用`n$link" }
             else { "$icon $stage · $($ev.bank)`n$line`n时间：$when`n影响：$($ev.scope)，期间不可使用`n$link" }
      if (Send-TGOk $tgToken $tgChat $msg) { $pushed += $key; $bankPush++; Start-Sleep -Milliseconds 400 }
    }
    # 支付宝开放平台的维护 / 异常类公告（3 天内、未推过的）
    foreach ($nt in @($bankData.alipay.notices)) {
      if (-not $nt) { continue }
      if ((($nowMs - [int64]$nt.pub) -gt 3 * 86400000) -or ($pushed -contains $nt.url)) { continue }
      if (Send-TGOk $tgToken $tgChat "🔵 支付宝公告`n$($nt.title)`n$($nt.url)") { $pushed += $nt.url; $bankPush++; Start-Sleep -Milliseconds 400 }
    }
  }

  @($pushed | Select-Object -Last 500) | Out-File -FilePath $pushedFile -Encoding UTF8
  Write-Host "  Telegram：本次新推送 虚拟币 $newCount 条，银行 / 支付宝 $bankPush 条" -ForegroundColor Cyan

  # ---- 链本身异常检测 + 推送（含恢复通知，自动去重）----
  # chainlog.txt 记的是「已经通知过的异常」，一行一条：链名|stall（出块停滞）或 链名|down（节点都连不上）
  # 通知发成功才记下来；发不出去的不记，下次运行会再发一次
  $chainLogFile = Join-Path $ScriptDir 'chainlog.txt'
  $prevState = @{}
  if (Test-Path $chainLogFile) {
    foreach ($ln in @(Get-Content $chainLogFile -Encoding UTF8 | Where-Object { $_ })) {
      $p = "$ln".Trim().Split('|')
      # 旧版只记链名，没有后面的种类：当成出块停滞
      if ($p[0]) { $prevState[$p[0]] = $(if (($p.Count -gt 1) -and $p[1]) { $p[1] } else { 'stall' }) }
    }
  }
  $newState = [ordered]@{}; $chainStall = @(); $chainDown = @()
  foreach ($ch in $ChainDefs) {
    $r = Test-ChainDef $ch
    # 第一次异常先等几秒再测一次，两次都异常才算：避免节点偶尔没回应就误报
    if ($r) { Start-Sleep -Seconds 4; $r = Test-ChainDef $ch }
    $prev = $prevState[$ch.k]
    if ($r) {
      if ($r.kind -eq 'stall') { $chainStall += $ch.k } else { $chainDown += $ch.k }
      if ($prev -eq $r.kind) { $newState[$ch.k] = $prev }   # 这个异常已经通知过，不重复发
      else {
        $msg = if ($r.kind -eq 'stall') { "🔴 链异常 · $($ch.k)`n$($r.reason)`n请留意该链充提是否受影响。" }
               else { "🟡 节点连不上 · $($ch.k)`n$($r.reason)`n目前看不出这条链的状态，不一定是链本身出问题；恢复连线后会再通知。" }
        if (Send-TGOk $tgToken $tgChat $msg) { $newState[$ch.k] = $r.kind } elseif ($prev) { $newState[$ch.k] = $prev }
      }
    } elseif ($prev) {
      $msg = if ($prev -eq 'stall') { "🟢 链已恢复 · $($ch.k)`n出块恢复正常。" } else { "🟢 节点恢复连线 · $($ch.k)`n出块正常。" }
      # 恢复通知发不出去：先留着记录，下次再发
      if (-not (Send-TGOk $tgToken $tgChat $msg)) { $newState[$ch.k] = $prev }
    }
  }
  @($newState.GetEnumerator() | ForEach-Object { "$($_.Key)|$($_.Value)" }) | Out-File -FilePath $chainLogFile -Encoding UTF8
  Write-Host "  链检测：出块异常 $($chainStall.Count) 条，节点连不上 $($chainDown.Count) 条" -ForegroundColor Cyan

  # ---- 公告来源失败提醒（含恢复通知）----
  # 来源连不上、或连得上但内容读不出来（多半是网页改版）时，「无维护」不可信，所以连着几次都这样就提醒一次
  # srcfail.txt 一行一条：来源名|分数|是否已通知(1/0)
  #   分数：失败一次 +1（最高 $SrcFailN），成功一次 -1。加到 $SrcFailN 才提醒，退回 0 才算恢复
  #   这样时好时坏的来源（例如从海外连银行官网偶尔超时）不会一下「异常」一下「恢复」地来回通知
  $SrcFailN = 3   # 每 5 分钟跑一次，连着失败 3 次约 15 分钟
  # 只管银行 / 支付宝的来源。交易所公告抓不到不推 Telegram，只在网页上显示黄色提示和原因
  $srcNow = [ordered]@{}   # 这次有问题的来源 → 原因
  $cxSrcNames = @($cxNames.Values | ForEach-Object { "${_}公告" })   # 旧版记录里的交易所来源名，读记录时跳过
  if ($bankData) {
    foreach ($s in @($bankData.sources)) {
      if (-not $s) { continue }
      if (-not $s.ok) { $srcNow[[string]$s.name] = '抓取失败' + $(if ($s.err) { "（$($s.err)）" } else { '' }) }
      elseif ($s.warn) { $srcNow[[string]$s.name] = [string]$s.warn }
    }
  } else { $srcNow['银行 / 支付宝抓取程序'] = '没有跑成功' }
  $srcFile = Join-Path $ScriptDir 'srcfail.txt'
  $srcPrev = @{}
  if (Test-Path $srcFile) {
    foreach ($ln in @(Get-Content $srcFile -Encoding UTF8 | Where-Object { $_ })) {
      $p = "$ln".Trim().Split('|')
      if (($p.Count -ge 3) -and ($cxSrcNames -notcontains $p[0])) { try { $srcPrev[$p[0]] = [pscustomobject]@{ n = [int]$p[1]; sent = ($p[2] -eq '1') } } catch {} }
    }
  }
  $srcNext = [ordered]@{}
  foreach ($name in @(@($srcNow.Keys) + @($srcPrev.Keys) | Select-Object -Unique)) {
    $o = $srcPrev[$name]; $n = 0; $sent = $false
    if ($o) { $n = $o.n; $sent = $o.sent }
    if ($srcNow.Contains($name)) {
      $n = [Math]::Min($n + 1, $SrcFailN)
      if (($n -ge $SrcFailN) -and (-not $sent)) {
        $sent = [bool](Send-TGOk $tgToken $tgChat "⚠ 公告抓不到 · $name`n$($srcNow[$name])`n已经连着 $SrcFailN 次抓不到。这是抓取程序连不上这个来源，不代表对方本身有问题；但修好之前收不到它的维护公告，它显示「无维护」不可信。")
      }
    } else {
      $n = $n - 1
      if ($n -le 0) {
        $n = 0
        # 恢复通知发成功才把记录清掉；发不出去就留着，下次再发
        if ($sent -and (Send-TGOk $tgToken $tgChat "🟢 公告来源恢复 · $name`n已经可以正常抓取。")) { $sent = $false }
      }
    }
    if (($n -gt 0) -or $sent) { $srcNext[$name] = "$n|$(if ($sent) { 1 } else { 0 })" }
  }
  @($srcNext.GetEnumerator() | ForEach-Object { "$($_.Key)|$($_.Value)" }) | Out-File -FilePath $srcFile -Encoding UTF8
  if ($srcNow.Count) { Write-Host "  公告来源：$($srcNow.Count) 个异常（$(@($srcNow.Keys) -join '、')）" -ForegroundColor DarkYellow }

  # ---- 每小时定时排查报告（北京时间每个整点一次）----
  # GitHub 定时触发不准时，整点没跑到也会在该小时内第一次运行时补发
  $bjNow = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
  $slot = $bjNow.ToString('yyyy-MM-dd-HH')
  if ($slot) {
    $reportFile = Join-Path $ScriptDir 'lastreport.txt'
    $lastSlot = ''; if (Test-Path $reportFile) { $lastSlot = "$(Get-Content $reportFile -Encoding UTF8 -Raw)".Trim() }
    if ($slot -ne $lastSlot) {
      $chainParts = @()
      if ($chainStall.Count) { $chainParts += '⚠ 出块异常：' + ($chainStall -join '、') }
      if ($chainDown.Count)  { $chainParts += '节点连不上：' + ($chainDown -join '、') }
      $chainLine = if ($chainParts.Count) { $chainParts -join '；' } else { '五条链全部正常 ✅' }
      # 交易所公告没抓成功时，「0 条」不可信，要在报告里讲清楚
      $cxLine = "$($toNotify.Count) 条" + $(if ($cxWarn) { "（⚠ $cxWarn，可能不完整）" } else { '' })
      $bankLine = '抓取失败 ⚠'; $aliLine = '抓取失败 ⚠'
      if ($bankData) {
        # 银行官网公告（部分服务可能受影响）不算「维护中」，另外注明
        $hardEv = @($bankData.events | Where-Object { $_ -and ($_.sev -ne 'partial') })
        $softEv = @($bankData.events | Where-Object { $_ -and ($_.sev -eq 'partial') })
        $bNow  = @($hardEv | Where-Object { ([int64]$_.s -le $nowMs) -and ([int64]$_.e -ge $nowMs) } | ForEach-Object { $_.bank } | Select-Object -Unique)
        $bSoon = @($hardEv | Where-Object { ([int64]$_.s -gt $nowMs) -and (([int64]$_.s - $nowMs) -le 86400000) } | ForEach-Object { $_.bank } | Select-Object -Unique)
        $pNow  = @($softEv | Where-Object { ([int64]$_.s -le $nowMs) -and ([int64]$_.e -ge $nowMs) } | ForEach-Object { $_.bank } | Select-Object -Unique)
        $bankLine = if ($bNow.Count) { '⚠ 维护中：' + ($bNow -join '、') } elseif ($bSoon.Count) { '24小时内维护：' + ($bSoon -join '、') } else { '无维护 ✅' }
        if ($pNow.Count) { $bankLine += "（官方公告进行中：$($pNow -join '、')，部分服务可能受影响）" }
        $aNow = @($bankData.alipay.events | Where-Object { $_ -and ([int64]$_.s -le $nowMs) -and ([int64]$_.e -ge $nowMs) })
        $aNew = @($bankData.alipay.notices | Where-Object { $_ -and (($nowMs - [int64]$_.pub) -le 3 * 86400000) })
        $aliLine = if ($aNow.Count) { '⚠ 维护中' } elseif ($aNew.Count) { "近3天公告 $($aNew.Count) 条" } else { '无维护公告 ✅' }
        # 来源连不上、或内容读不出来时「无维护」不可信，要在报告里讲清楚
        $failBank = @($bankData.sources | Where-Object { $_ -and ((-not $_.ok) -or $_.warn) -and ($_.name -ne '支付宝开放平台') } | ForEach-Object { $_.name })
        $failAli  = @($bankData.sources | Where-Object { $_ -and ((-not $_.ok) -or $_.warn) -and ($_.name -eq '支付宝开放平台') })
        if ($failBank.Count) { $bankLine += "（⚠ 来源异常：$($failBank -join '、')）" }
        if ($failAli.Count)  { $aliLine  += '（⚠ 公告来源异常）' }
      }
      $report = "📊 监控台 · 每小时排查`n$($bjNow.ToString('MM-dd HH:mm')) 北京`n———————`n链状态：$chainLine`nUSDT场外：买 ¥$okxBuy / 卖 ¥$okxSell`n近3天维护/暂停/升级：$cxLine`n银行：$bankLine`n支付宝：$aliLine`n———————`nhttps://workschedule-netizen.github.io/crypto-monitor/"
      # 发成功才记下这个整点；发不出去的话，下次运行（约 5 分钟后）会再补发
      if (Send-TGOk $tgToken $tgChat $report) {
        $slot | Out-File -FilePath $reportFile -Encoding UTF8
        Write-Host "  已发送每小时排查报告（$slot）" -ForegroundColor Cyan
      } else { Write-Host "  每小时排查报告发送失败，下次运行再试" -ForegroundColor DarkYellow }
    }
  }
}

# 手动触发（workflow_dispatch）时发一条测试消息，确认推送通道
if ($tgToken -and $tgChat -and $env:GITHUB_EVENT_NAME -eq 'workflow_dispatch') {
  $tmsg = "✅ 监控台 · 推送测试成功`n通道正常，当前共 $totalCount 条相关公告。`n$($PushChains -join ' / ') 相关的交易所公告、银行维护（一周前 / 前一日 / 前一小时）和链异常会自动通知你。"
  if (Send-TGOk $tgToken $tgChat $tmsg) { Write-Host "  已发送手动测试消息" -ForegroundColor Cyan }
}

Write-Host '  正在打开浏览器 ...' -ForegroundColor Cyan
if (-not $env:GITHUB_ACTIONS) { try { Start-Process $OutFile } catch {} }






























