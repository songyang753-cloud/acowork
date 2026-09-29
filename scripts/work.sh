#!/bin/zsh
# acowork 工作区注册表:多会话不串台。
# 取代旧版全局单文件 work-pointer——两个 Claude 会话并发跑 acowork 时指针互相覆盖,
# 后者让前者不可恢复(2026-09-29 实测:17:08/17:09/17:39 三轮互踩)。改为注册表:
# 一轮一行,add 时登记、close 时收尾,list --active 即断点恢复入口。
#
# 用法:
#   work.sh add <WORK> "<一句话任务摘要>"              登记新轮(已存在则重开为 active)
#   work.sh close <WORK> done|done-with-exceptions|abandoned
#   work.sh list [--active]                           全部/未收尾工作区(恢复入口)
#
# 环境变量:ACOWORK_STATE_DIR(默认 ~/.local/state/acowork;测试注入隔离目录)
# 退出码:0=成功 1=未找到/校验失败 2=用法错误
#
# 防污染:WORK 路径(realpath 后)必须以 /tmp/acowork. 开头且是目录——
# 与 SKILL.md 恢复流程的前缀校验同一规则,不许注册任意路径。

set -u
ACOWORK_STATE_DIR=${ACOWORK_STATE_DIR:-$HOME/.local/state/acowork}
REG="$ACOWORK_STATE_DIR/workspaces.json"

usage() {
  print -u2 "usage: work.sh add <WORK> \"<summary>\" | close <WORK> <done|done-with-exceptions|abandoned> | list [--active]"
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd=$1; shift

case "$cmd" in
  add|close|list) ;;
  *) usage ;;
esac

mkdir -p "$ACOWORK_STATE_DIR" && chmod 700 "$ACOWORK_STATE_DIR" 2>/dev/null

python3 - "$REG" "$cmd" "$@" <<'PY'
import json, sys, os, fcntl, datetime

REG, cmd = sys.argv[1], sys.argv[2]
args = sys.argv[3:]

def now():
    return datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')

def load():
    if os.path.exists(REG):
        try:
            return json.load(open(REG))
        except Exception:
            pass
    return {"workspaces": []}

def save(d):
    tmp = REG + '.tmp'
    json.dump(d, open(tmp, 'w'), ensure_ascii=False, indent=1)
    os.replace(tmp, REG)

def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)

lock = open(os.path.join(os.path.dirname(REG) or '.', '.reg.lock'), 'w')
fcntl.flock(lock, fcntl.LOCK_EX)

if cmd == 'add':
    if len(args) != 2:
        die('usage: work.sh add <WORK> "<summary>"', 2)
    work, summary = args
    real = os.path.realpath(work)
    # macOS /tmp → /private/tmp 软链:realpath 后两个前缀都认
    if not (real.startswith('/tmp/acowork.') or real.startswith('/private/tmp/acowork.')):
        die(f'拒绝注册: {work}(realpath={real}) 不在 /tmp/acowork. 前缀下——防指针污染')
    if not os.path.isdir(real):
        die(f'拒绝注册: {work} 不是目录')
    d = load()
    for w in d['workspaces']:
        if w['work'] == work:
            w.update({'summary': summary, 'status': 'active', 'started': now(), 'closed': None})
            save(d); print(f'reopened: {work} → active')
            sys.exit(0)
    d['workspaces'].append({'work': work, 'summary': summary, 'status': 'active', 'started': now(), 'closed': None})
    save(d)
    print(f'registered: {work} → active')

elif cmd == 'close':
    if len(args) != 2:
        die('usage: work.sh close <WORK> <done|done-with-exceptions|abandoned>', 2)
    work, status = args
    if status not in ('done', 'done-with-exceptions', 'abandoned'):
        die('status 必须是 done | done-with-exceptions | abandoned', 2)
    d = load()
    for w in d['workspaces']:
        if w['work'] == work:
            w['status'] = status; w['closed'] = now()
            save(d); print(f'closed: {work} → {status}')
            sys.exit(0)
    die(f'未注册的工作区: {work}(先 work.sh add)')

elif cmd == 'list':
    active_only = '--active' in args
    d = load()
    rows = [w for w in d['workspaces'] if (not active_only or w.get('status') == 'active')]
    if not rows:
        print('(无)' if active_only else '(空注册表)')
    for w in reversed(rows):   # 新的在前
        print(f"{w.get('status','?'):22} {w.get('work','?'):28} {w.get('started','?')}  {w.get('summary','')}")
    sys.exit(0)
PY
