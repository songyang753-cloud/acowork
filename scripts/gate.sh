#!/bin/zsh
# acowork 机器放行门:汇报前必跑,把 SKILL.md 里的 prose 纪律变成机器检查。
# 设计来源:K-Dense test_repo_contract(机器强制 AGENTS.md 规则)+ wshobson doc_gardener
# (漂移检查带 Fix 行)+ agent-harness loop_controller(close 遇 unverified exit 4)。
#
# 用法: gate.sh <WORK> [--final]
#   --final  终验模式:额外检查 ACCEPTANCE 对账(G6);有违规 exit 1,不许宣布完成
# 退出码:0=放行 1=有违规 2=用法错误
#
# 检查项:
#   G1 对账   reviews/replies 每个文件 ↔ dispatch.log 成功派发一一对应(双向:幽灵/丢失)
#   G2 内容   每个有效回包过实质内容门禁(判据与 dispatch 相同,已在真实评审上验证)
#   G3 状态   有派发但 state.json 停在 probe = 断点恢复是白纸;任务卡须入状态机
#   G4 判据   REQUIREMENTS.md 存在、每条 R# 带 oracle 标记、与冻结公证 SHA-256 一致
#   G5 账本   ledger.json 存在且数字守恒(confirmed ≤ Σraw;失败派发入 skipped;used 有成功派发)
#   G6 终验   (--final)ACCEPTANCE 存在且覆盖全部 R#;review-only 模式发现处置计数守恒
#   G7 卫生   无 *.tmp/*.failed 残留;陈旧锁只警告不删(绝不删他人持有的锁)
#   G8 注册   工作区已在 work.sh 注册(未注册=断点恢复找不到)
#
# 环境变量:ACOWORK_STATE_DIR(默认 ~/.local/state/acowork;测试注入隔离目录)

set -u
ACOWORK_STATE_DIR=${ACOWORK_STATE_DIR:-$HOME/.local/state/acowork}
REG="$ACOWORK_STATE_DIR/workspaces.json"

[[ $# -ge 1 ]] || { print -u2 "usage: gate.sh <WORK> [--final]"; exit 2 }
WORK_ARG=$1; WORK=${1:a}
shift
FINAL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --final) FINAL=true ;;
    *) print -u2 "unknown option: $1(拼错参数会静默跳过 G6 终验=假绿路径,显式拒绝)"; exit 2 ;;
  esac
  shift
done
[[ -d "$WORK" ]] || { print -u2 "workspace not found: $WORK_ARG"; exit 2 }
[[ "$WORK" == /tmp/acowork.* ]] || { print -u2 "拒绝:$WORK 不在 /tmp/acowork. 前缀下"; exit 2 }
if [[ "$FINAL" == true ]]; then FFLAG=1; else FFLAG=0; fi

python3 - "$WORK" "$FFLAG" "$REG" <<'PY'
import json, sys, os, re, glob, hashlib, datetime

work, final, reg = sys.argv[1], sys.argv[2] == '1', sys.argv[3]
V, W = [], []          # violations / warnings(警告也带 Hint——输出契约对称)
def bad(g, what, fix): V.append((g, what, fix))
def warn(g, what, hint='不阻断'): W.append((g, what, hint))

def rd(p):
    try: return open(p, errors='replace').read()
    except Exception: return None

# ── 载入现场 ──
log = []
for line in (rd(os.path.join(work, 'dispatch.log')) or '').splitlines():
    line = line.strip()
    if line.startswith('{'):
        try: log.append(json.loads(line))
        except Exception: pass
ok_entries = [e for e in log if e.get('ok')]
ok_agents  = {e.get('agent') for e in ok_entries}
failed_agents = {e.get('agent') for e in log if not e.get('ok')} - ok_agents

reviews = sorted(glob.glob(os.path.join(work, 'reviews', '*.md')))
replies = sorted(glob.glob(os.path.join(work, 'replies', '*.md')))
taskcards = sorted(glob.glob(os.path.join(work, 'tasks', 'TASK-*.md')))

# ── G1 对账:文件 ↔ 成功派发 ──
legacy_warned = False
matched_files = set()
for f in reviews + replies:
    base = os.path.basename(f)
    m = re.match(r'^(?:REVIEW|REPLY)-(.+)-by-(\w+)\.md$', base)
    if not m:
        bad('G1', f'{base} 文件名不合契约(REVIEW/REPLY-<task>-by-<agent>.md)', '按 protocol.md §2 命名')
        continue
    tid, agent = m.group(1), m.group(2)
    hit = [e for e in ok_entries if e.get('agent') == agent and e.get('task') == tid]
    if hit:
        matched_files.add(f); continue
    legacy = [e for e in ok_entries if e.get('agent') == agent and e.get('task') is None]
    if legacy:
        matched_files.add(f)
        if not legacy_warned:
            warn('G1', '存在旧格式派发记录(无 task 字段),按 agent 粗对账', '不阻断;下一轮用 v1.4 dispatch 产出精确对账记录')
            legacy_warned = True
        continue
    bad('G1', f'{base} 无对应成功派发(幽灵文件或失败残料)', '删除;需要该评审就用 dispatch --out 重新派发')
for e in ok_entries:
    out = e.get('out')
    if out and not os.path.exists(out):
        bad('G1', f'成功派发({e.get("agent")} task={e.get("task")})的回包文件丢失: {out}', '从 stdout 重存或重派')
    if not e.get('ok') and e.get('out') and os.path.exists(e.get('out')):
        bad('G1', f'失败派发残留回包文件: {e.get("out")}', 'dispatch 已保证失败不留文件——此为手改痕迹,删除')

# ── G2 内容:有效回包过实质门禁(判据与 dispatch.has_substance 相同) ──
SUB = [r'回声确认', r'已检查维度|零发现|无发现',
       r'P[012]([^0-9A-Za-z]|$)|"severity"|"issue_type"|"finding"', r'^\| *[0-9]+ *\|']
for f in sorted(matched_files):
    txt = rd(f) or ''
    if not any(re.search(p, txt, re.M) for p in SUB):
        bad('G2', f'{os.path.basename(f)} 无实质内容标记(疑似计划书/截断/空转)',
            '该回包不得作为依据;用 dispatch 重新派发(自动重试一次,仍无实质内容即失败)')

# ── G3 状态机 ──
if log:
    state = None
    try: state = json.loads(rd(os.path.join(work, 'state.json')) or 'null')
    except Exception: pass
    if state is None:
        bad('G3', 'dispatch.log 非空但 state.json 缺失/不可解析', '恢复 state.json;v1.4 起派发自动 upsert tasks[]')
    else:
        if state.get('phase') == 'probe':
            bad('G3', f'有 {len(log)} 次派发但 state.json 仍停在 probe——断点恢复=白纸',
                '把 phase 推进到实际阶段;v1.4 起任务状态由 dispatch 自动写,phase 由主持者推进')
        ids = {t.get('id') for t in state.get('tasks', [])}
        for c in taskcards:
            m = re.match(r'TASK-(.+)\.md$', os.path.basename(c))
            if m and m.group(1) not in ids:
                bad('G3', f'{os.path.basename(c)} 未入状态机(未派发或旧轮遗留)', '派发(v1.4 自动入账)或删除该卡')

# ── G4 判据:REQUIREMENTS + oracle + 冻结公证 ──
req_txt = None
if log:
    req_txt = rd(os.path.join(work, 'REQUIREMENTS.md'))
    if req_txt is None:
        bad('G4', '有派发但无 REQUIREMENTS.md(spec-check 无基准)', 'plan 阶段冻结需求清单,每条带 oracle')
if req_txt is not None:
    rids = []
    for line in req_txt.splitlines():
        m = re.match(r'^(R\d+)\s*[:：]?\s*(.*)$', line.strip())
        if not m: continue
        rids.append(m.group(1))
        body = m.group(2)
        if not re.search(r'oracle|验证|期望', body, re.I):
            bad('G4', f'{m.group(1)} 无 oracle(验证命令+期望结果)——验收时无判据可对',
                f'{m.group(1)}: <需求> oracle: <命令> → <期望结果>')
    anchor = os.path.join(work, '.requirements.sha256')
    if os.path.exists(anchor):
        h = hashlib.sha256(req_txt.encode()).hexdigest()
        if rd(anchor).strip() != h:
            bad('G4', 'REQUIREMENTS.md 与冻结公证 SHA-256 不符(判据被改?)',
                '确属需求变更→换新版本重冻+更新公证;否则恢复原判据')
    else:
        warn('G4', 'REQUIREMENTS 未做冻结公证', '不阻断;冻结后 shasum -a 256 REQUIREMENTS.md > .requirements.sha256')
else:
    rids = []

# ── G5 账本 ──
raw_total = None
if log:
    ledger = None
    try: ledger = json.loads(rd(os.path.join(work, 'ledger.json')) or 'null')
    except Exception: pass
    if ledger is None:
        bad('G5', '有派发但无/坏 ledger.json(诚实计数无凭)', '写 ledger.json,单位见 protocol.md §2')
    else:
        fr = ledger.get('findings_raw')
        if isinstance(fr, dict): raw_total = sum(v for v in fr.values() if isinstance(v, (int, float)))
        elif isinstance(fr, (int, float)): raw_total = fr
        fc = ledger.get('findings_confirmed')
        conf = fc.get('total') if isinstance(fc, dict) else fc
        if isinstance(conf, (int, float)) and isinstance(raw_total, (int, float)) and conf > raw_total:
            bad('G5', f'findings_confirmed({conf}) > findings_raw 总和({raw_total})——单位混乱或美化',
                'confirmed 只能是 raw 的子集(条);行级修改数记 fix_edits(处),单位见 protocol.md §2')
        for a in ledger.get('agents_used', []) or []:
            if a not in ok_agents:
                bad('G5', f'ledger 记 agents_used 含 {a} 但 dispatch.log 无其成功派发', '修正账本')
        skipped = {s.get('name') if isinstance(s, dict) else s
                   for s in ledger.get('agents_skipped', []) or []}
        for a in failed_agents:
            if a not in skipped:
                bad('G5', f'{a} 有失败派发且无成功记录,但未入 agents_skipped', '如实记 skipped+原因(诚实计数)')

# ── G6 终验(--final)──
if final:
    accs = sorted(glob.glob(os.path.join(work, 'ACCEPTANCE-*.md')))
    if not accs and log:
        bad('G6', '无 ACCEPTANCE-*.md——完成声明无对账(merge 完成≠任务完成)', '按 protocol.md §7b 逐条对账写 ACCEPTANCE')
    if accs:
        acc = rd(accs[-1]) or ''
        if re.search(r'发现对账|review-only', acc):
            m = re.search(r'raw\s*=\s*(\d+)', acc)
            parts = dict(re.findall(r'(采纳|驳回|待办)\s*=\s*(\d+)', acc))
            missing = [k for k in ('采纳', '驳回', '待办') if k not in parts]
            if not m or missing:
                need = 'raw=' + ('' if m else 'raw ') + ' '.join(missing)
                bad('G6', f'review-only 验收对账行缺项(缺: {need or "raw"})', '补: 发现对账: raw=N 采纳=a 驳回=d 待办=t')
            else:
                raw = int(m.group(1)); s = sum(int(v) for v in parts.values())
                if s != raw:
                    bad('G6', f'发现处置不守恒: 采纳+驳回+待办={s} ≠ raw={raw}', '每条 raw finding 必须有落点')
                if raw_total is not None and raw != raw_total:
                    bad('G6', f'验收 raw({raw}) ≠ ledger findings_raw({int(raw_total)})', '对齐两处计数')
        else:
            for rid in rids:
                if not re.search(rf'{rid}\b', acc):
                    bad('G6', f'ACCEPTANCE 未覆盖 {rid}', f'逐条对账,未达标走回炉或报例外——不许跳条')

# ── G7 卫生 ──
for pat in ('*.tmp', '*.tmp.*', '*.failed'):
    for f in glob.glob(os.path.join(work, pat)):
        bad('G7', f'残留临时/失败文件: {os.path.basename(f)}', '清理(失败回包应由 dispatch 自动删除,手改痕迹须清)')
locks_dir = os.path.join(os.path.dirname(reg), 'locks')
if os.path.isdir(locks_dir):
    import subprocess
    for ld in glob.glob(os.path.join(locks_dir, '*')):
        pid = (rd(os.path.join(ld, 'pid')) or '').strip()
        if pid:
            try: os.kill(int(pid), 0); continue   # 活锁:不动
            except Exception: pass
        warn('G7', f'陈旧锁可回收: {os.path.basename(ld)}', '不阻断;gate 不删锁(不猜所有权),下一次 dispatch 自动回收')

# ── G8 注册 ──
registered = False
try:
    rj = json.loads(rd(reg) or '{"workspaces":[]}')
    for w in rj.get('workspaces', []):
        if w.get('work') == work:
            registered = True
            if final and w.get('status') == 'active':
                warn('G8', '工作区仍为 active', '不阻断;gate 通过后 work.sh close 收尾')
            break
except Exception: pass
if not registered:
    bad('G8', '工作区未注册(work.sh add)', 'SKILL.md §1:开轮必登记,否则断点恢复找不到')

# ── 输出 ──
print(f'== acowork gate: {work}{" [FINAL]" if final else ""} ({datetime.datetime.now():%Y-%m-%d %H:%M:%S}) ==')
print('图例: G1对账 G2内容 G3状态 G4判据 G5账本 G6终验 G7卫生 G8注册')
for g, what, fix in V: print(f'❌ {g} {what}\n     Fix: {fix}')
for g, what, hint in W: print(f'⚠️  {g} {what}\n     Hint: {hint}')
if not V and not W:
    print('✅ 全部检查通过')
elif not V:
    print(f'✅ 通过({len(W)} 警告,不阻断)')
from collections import Counter
vc = Counter(g for g, _, _ in V)
detail = ' '.join(f'{k}:{v}' for k, v in sorted(vc.items()))
print(f'gate: {len(V)} 违规{ "(" + detail + ")" if detail else "" } / {len(W)} 警告{" [final]" if final else ""}' + (' → 不放行' if V else ' → 放行'))
sys.exit(1 if V else 0)
PY
