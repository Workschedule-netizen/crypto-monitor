# -*- coding: utf-8 -*-
"""群组监听：用自己的 Telegram 账号监听指定群组，消息里出现关键词就用机器人实时推送。

用法：
  python listener.py --list   列出这个账号加入的所有群组和它们的 ID
  python listener.py          开始监听

config.json 的 our_channels 有填的话：消息提到我方通道代号，只推送跟我方通道有关的那几行；
完全没写代号的通知整条照推；只写了别家代号的不推送。问句（「维护了吗」）一律不推送。
chase_keywords（追款、误补上分这类）不受上面的规则限制，出现就整条原样推送。

设定都在同一个文件夹的 config.json。第一次运行会要求输入手机号和验证码，
登录后会产生 listener.session，那个文件等于账号的登录凭证，不要外传、不要上传。
"""
import asyncio
import json
import re
import sys
import time
import traceback
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from telethon import TelegramClient, errors, events
from telethon.utils import get_display_name

BASE = Path(__file__).resolve().parent
BJ = timezone(timedelta(hours=8))   # 时间一律显示北京时间

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def log(msg):
    line = f"[{datetime.now(BJ):%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    try:
        with open(BASE / 'listener.log', 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass


def clean_list(values):
    return [str(v).strip() for v in (values or []) if v is not None and str(v).strip()]


# 行首的一串英数字，例如「8003小额 400-3000」的 8003；日期（2026-10-05、2026年10月）和金额区间（1000-5000）不算
LEAD_CODE = re.compile(r'\W*(?!\d{4}[-/.年]\d)([0-9A-Za-z]{4,})')
SENTENCE_END = re.compile(r'(?<=[。！!？?\n])')
# config.json 没写 question_words 时用这组：句子里有这些字就当成是在问，不是通知
QUESTION_WORDS = ['吗', '嗎', '?', '？', '了没', '了沒', '是不是', '有没有', '有沒有', '什么时候', '什麼時候']


def channel_pattern(codes):
    """我方通道代号 → 比对用的正则，不分大小写。
    代号前后不能紧贴英文或数字，免得 8005 误中 18005、Fourjjcaca 误中 Fourjjcaca02。"""
    if not codes:
        return None
    alt = '|'.join(re.escape(c) for c in sorted(codes, key=len, reverse=True))
    return re.compile(rf'(?<![0-9A-Za-z])(?:{alt})(?![0-9A-Za-z])', re.IGNORECASE)


def group_patterns(name, channels, scoped):
    """这个群里算数的我方代号、在这个群不算数的限定代号，各编成一个正则。
    scoped 是 {群名里要有的字: [代号]}，例如 8007 只在群名有「宝诺」的群才算我方通道。"""
    off = [c for key, codes in scoped.items() if key not in name for c in codes]
    return channel_pattern([c for c in channels if c not in off]), channel_pattern(off)


def only_ours(text, ours, foreign):
    """筛出跟我方通道有关的内容，回传 (内容, 有没有提到我方通道, 去掉了几行)。
    提到我方代号的行保留；开头是别家代号、或出现在这个群不算数的限定代号的行去掉；其余说明文字照留。"""
    kept, found, dropped = [], False, 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if ours and ours.search(line):
            found = True
        else:
            m = LEAD_CODE.match(line)
            if (foreign and foreign.search(line)) or (m and any(c.isdigit() for c in m.group(1))):
                dropped += 1
                continue
        kept.append(line)
    return '\n'.join(kept), found, dropped


def keyword_hits(text, keywords, questions):
    """消息里出现的关键词；问句（「维护了吗」「开启了吗？」）里的不算。"""
    hit = []
    for part in SENTENCE_END.split(text):
        low = part.lower()
        if any(q in low for q in questions):
            continue
        hit += [k for k in keywords if k in low and k not in hit]
    return hit


def ignore_rules(cfg):
    """ignore_keywords（照字面比对）和 ignore_patterns（正则）合成一组，命中任何一个就整条不推送。"""
    rules = [re.compile(re.escape(k), re.IGNORECASE) for k in clean_list(cfg.get('ignore_keywords'))]
    for p in clean_list(cfg.get('ignore_patterns')):
        try:
            rules.append(re.compile(p, re.IGNORECASE))
        except re.error as e:
            sys.exit(f'config.json 的 ignore_patterns 写法有误：{p}（{e}）')
    return rules


def what_to_push(text, keywords, chase, ignore, questions, ours, foreign):
    """这条消息要推送的话回传 (命中的关键词, 推送内容, 是不是追款)，不用推送回传 None。"""
    low = text.lower()
    if any(r.search(text) for r in ignore):
        return None
    hit = [k for k in chase if k in low]
    if hit:
        # 追款漏掉会赔钱：问句也推、不看通道代号，整条原样推送（订单号、金额都要留着）
        return hit, text, True
    hit = keyword_hits(text, keywords, questions)
    if not hit:
        return None
    if ours or foreign:
        text, found, dropped = only_ours(text, ours, foreign)
        # 提到我方通道 → 推送筛过的内容；完全没写代号 → 整条照推；只写了别家代号 → 不推送
        if dropped and not found:
            return None
    return hit, text, False


def load_config():
    path = BASE / 'config.json'
    if not path.exists():
        sys.exit('找不到 config.json，请把它和 listener.py 放在同一个文件夹')
    try:
        # utf-8-sig：用记事本存档时前面多出来的 BOM 也能读
        with open(path, encoding='utf-8-sig') as f:
            cfg = json.load(f)
    except json.JSONDecodeError as e:
        sys.exit(f'config.json 格式有误（第 {e.lineno} 行附近）：{e.msg}')
    if not cfg.get('api_id') or not cfg.get('api_hash'):
        sys.exit('config.json 里的 api_id / api_hash 还没填')
    return cfg


def send_push(token, chat_id, text):
    """用机器人发一条消息，成功回传 True。被限流或一时连不上会再试，一条消息最多发 3 次。"""
    data = json.dumps({'chat_id': chat_id, 'text': text, 'disable_web_page_preview': True}).encode('utf-8')
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{token}/sendMessage',
        data=data, headers={'Content-Type': 'application/json'})
    for left in (2, 1, 0):   # 还能再试几次
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.status == 200
        except urllib.error.HTTPError as e:
            body = e.read().decode('utf-8', 'replace')
            # 429 = 发太快被限流（同一个群一分钟约 20 条），5xx = Telegram 那边一时出错：等一下再发，不要直接丢掉
            if left and (e.code == 429 or e.code >= 500):
                try:
                    wait = int(json.loads(body)['parameters']['retry_after']) + 1   # 限流时回应里会写要等几秒
                except Exception:
                    wait = 3
                time.sleep(min(wait, 60))
                continue
            log(f'推送失败（HTTP {e.code}）：{body[:200]}')
        except urllib.error.URLError as e:
            # 连线阶段就失败（断网、DNS 解析不了）：消息还没送出去，再试不会重复
            if left:
                time.sleep(3)
                continue
            log(f'推送失败：{type(e).__name__}')
        except Exception as e:
            # 其他情况（例如送出后等回应超时）不重试：可能其实已经发成功，再发会重复
            log(f'推送失败：{type(e).__name__}')
        return False
    return False


async def list_groups(client):
    print('\n这个账号加入的群组 / 频道（把要监听的名称或 ID 填进 config.json 的 groups）：\n')
    lines = []
    async for d in client.iter_dialogs():
        if d.is_group or d.is_channel:
            kind = '群组' if d.is_group else '频道'
            lines.append(f'{d.id}\t{kind}\t{d.name}')
            print('  ' + lines[-1])
    # 同时存成文字档，方便用记事本打开来复制 ID
    try:
        with open(BASE / '群组列表.txt', 'w', encoding='utf-8-sig') as f:
            f.write('\n'.join(lines) + '\n')
        print(f'\n共 {len(lines)} 个，已存到同一个文件夹的「群组列表.txt」，可以用记事本打开来复制 ID。\n')
    except OSError:
        print()


async def resolve_groups(client, wanted):
    """config 里的群组可以填名称或 ID，这里换成 {ID: 名称}。"""
    found = {}
    async for d in client.iter_dialogs():
        if (d.is_group or d.is_channel) and (str(d.id) in wanted or d.name in wanted):
            found[d.id] = d.name
    known = {str(i) for i in found} | set(found.values())
    return found, [w for w in wanted if w not in known]


async def main():
    cfg = load_config()
    client = TelegramClient(str(BASE / 'listener'), int(cfg['api_id']), str(cfg['api_hash']).strip())
    try:
        # 第一次会在这里问手机号、验证码、两步验证密码。
        # 密码改成输入时看得到（预设是隐藏的，盲打容易错）；输入完注意不要把画面截图外传
        await client.start(password=lambda: input('请输入两步验证密码（输入的字会显示在画面上）: '))
    except errors.PasswordHashInvalidError:
        sys.exit('\n两步验证密码连续 3 次都不对，程序先停下。\n'
                 '这里要的是 Telegram「设置 → 隐私和安全 → 两步验证」里设的那组密码。\n'
                 '输入前先切到英文输入法，或在记事本打好后复制，回到这个窗口按鼠标右键贴上。')
    log(f'已登录：{get_display_name(await client.get_me())}')

    if '--list' in sys.argv:
        await list_groups(client)
        return

    token = str(cfg.get('bot_token', '')).strip()
    push_to = clean_list(cfg.get('push_to'))
    keywords = [k.lower() for k in clean_list(cfg.get('keywords'))]
    ignore = ignore_rules(cfg)
    chase = [k.lower() for k in clean_list(cfg.get('chase_keywords'))]
    questions = [q.lower() for q in clean_list(cfg.get('question_words', QUESTION_WORDS))]
    channels = clean_list(cfg.get('our_channels'))   # {代号: 名称}，只用到代号
    scoped = {k: clean_list(v) for k, v in (cfg.get('channel_only_in') or {}).items()}
    if not token or not push_to:
        sys.exit('config.json 里的 bot_token / push_to 还没填')
    if not keywords:
        sys.exit('config.json 里的 keywords 是空的')

    groups, missing = await resolve_groups(client, clean_list(cfg.get('groups')))
    for m in missing:
        log(f'找不到群组：{m}（名称要完全一样，或改填 --list 列出来的 ID）')
    # 推送目标本身不监听：否则机器人推过去的消息又被抓到，会无限循环
    for p in push_to:
        if p.lstrip('-').isdigit():
            groups.pop(int(p), None)
    if not groups:
        sys.exit('没有可以监听的群组，请检查 config.json 的 groups')
    bot_id = int(token.split(':')[0]) if token.split(':')[0].isdigit() else None
    patterns = {gid: group_patterns(gname, channels, scoped) for gid, gname in groups.items()}

    @client.on(events.NewMessage(chats=list(groups)))
    async def on_message(event):
        try:
            ours, foreign = patterns.get(event.chat_id, (None, None))
            picked = what_to_push(event.raw_text or '', keywords, chase, ignore, questions, ours, foreign)
            if not picked:
                return
            hit, text, is_chase = picked
            if bot_id and event.sender_id == bot_id:
                return
            try:
                sender = await event.get_sender()
            except Exception:
                sender = None   # 查不到发送人不影响通知，照样推送
            who = get_display_name(sender) if sender else '未知'
            name = groups.get(event.chat_id, str(event.chat_id))
            when = event.date.astimezone(BJ).strftime('%m-%d %H:%M:%S')
            body = text if len(text) <= 1500 else text[:1500] + '…'
            title = '🚨 追款提醒' if is_chase else '🔔 群组通知'
            msg = (f'{title} · {name}\n发送人：{who}\n'
                   f'时间：{when}（北京）\n———————\n{body}')
            loop = asyncio.get_running_loop()
            results = await asyncio.gather(*[loop.run_in_executor(None, send_push, token, p, msg) for p in push_to])
            log(f'命中「{"、".join(hit)}」· {name} · {who} → 推送{"成功" if any(results) else "失败"}')
        except Exception as e:
            # 出错要记进 listener.log：否则这条消息就无声无息地漏掉了
            log(f'处理消息出错（这条没有推送）：{type(e).__name__}: {e}')

    log(f'开始监听 {len(groups)} 个群组：' + '、'.join(groups.values()))
    log('关键词：' + '、'.join(keywords))
    if chase:
        log('追款关键词（整条原样推送）：' + '、'.join(chase))
    if channels:
        log(f'我方通道代号 {len(channels)} 个：提到的只推送相关的行，只写了别家代号的不推送')
    await client.run_until_disconnected()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    except Exception:
        # 没预料到的错误也记进 listener.log：窗口关掉以后还查得到是停在哪里
        log('程序出错停止：\n' + traceback.format_exc())
        sys.exit(1)
