#!/bin/zsh
# acowork 统一派活器:把任务卡派给指定 agent,封装各家 CLI 姿势差异。
# 主持者只用这一个入口派活,不需要记住每家的坑。
# probe.sh 也复用本脚本(姿势/超时/归因单源,不双份维护)。
#
# v1.4 新增(2026-09-29 四轮真实使用暴露问题全修,见 references/bad-cases.md B11-B13/A8-A9/C14):
#   --out <file>     成功才把回包写到该文件;失败确保该文件不存在(杀幽灵评审文件 B11)
#   --loose-format   跳过回包实质内容门禁(confirm 一句话卡用)
#   --wait-lock <s>  同 agent 并发派发时等锁最多 s 秒(默认 0=快速失败 busy;A8 busy≠死亡)
#   --retry 0|1      空回复/无实质内容自动重试 1 次(默认 1;probe 用 0)
#   内容门禁:协议注入且非 loose 时,回包须含实质标记(回声确认/发现结构/JSON 发现键/表格行),
#             纯"I'll do X"计划书判失败(B12:353 字 stub 曾被判 ok:true)
#   stdout 落文件捕获:进程组外 setsid 孙进程持有管道不再拖死超时(B13:实测 timeout 3s 拖到 20s→0s)
#   agent 锁:同 agent 并发派发互斥;busy 快速失败、死锁自动回收(A9:并发会话 probe 误摘除)
#   state.json 自动推进:taskfile 在 */tasks/ 下时,派发结果 upsert 进状态机(治「状态机永远停在 probe」)
#   meta 增 task/attempts/out/check/repo_mismatch;cwd 字段记录 --cwd 参数本身(修旧版记 shell pwd 的误导)
#
# 用法: dispatch.sh <grok|codex|opencode> <taskfile> [选项]
# 选项:
#   --readonly       评审模式:物理只读锁(grok=工具白名单/codex=read-only沙箱/opencode=plan agent)
#   --timeout <秒>   默认 300
#   --cwd <dir>      执行目录(写码任务传目标仓库);目录不存在=用法错误直接退出
#   --protocol <f>   协议文件前缀注入,默认脚本同目录 ../protocol.md;--no-protocol 跳过;
#                    显式指定的文件不存在=用法错误(静默无契约执行是假绿温床)
#   --continue       续最近会话(仅 grok/opencode;codex 不支持,显式报错)
#   --out <file>     回包落盘目标(成功才写,失败必删;目标目录必须已存在)
#   --loose-format   跳过内容门禁
#   --wait-lock <s>  并发锁等待秒数,默认 0
#   --retry 0|1      瞬态失败(空回复/无实质内容)自动重试 1 次,默认 1
#
# 环境变量(换机器只改这里;测试用它注入假 CLI 与隔离状态目录):
#   GROK_BIN / OPENCODE_BIN / CODEX_BIN
#   ACOWORK_STATE_DIR   锁与注册表所在目录,默认 ~/.local/state/acowork
#
# 输出:回包正文 → stdout;一行 JSON 元信息 → stderr(任务卡派发时自动追加到 $WORK/dispatch.log)
# 退出码:0=成功 1=agent失败(超时/额度/空回复/busy/无实质内容) 2=用法错误
#
# ok 判定原则(经交叉评审修订):
#   ok = 退出码==0 且输出非空 且(协议注入且非 loose 时)过实质内容门禁
#   ——错误关键词只归类原因,不参与 ok 判定(否则评审文本里提到 "quota" 会把成功回包误杀,实测踩过)

set -u
readonly SCRIPT_DIR=${0:A:h}
GROK_BIN=${GROK_BIN:-$HOME/.grok/bin/grok}
OPENCODE_BIN=${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}
CODEX_BIN=${CODEX_BIN:-/opt/homebrew/bin/codex}
ACOWORK_STATE_DIR=${ACOWORK_STATE_DIR:-$HOME/.local/state/acowork}

[[ $# -ge 2 ]] || { print -u2 "usage: dispatch.sh <grok|codex|opencode> <taskfile> [options]"; exit 2 }
agent=$1; taskfile=${2:a}
[[ -f "$taskfile" ]] || { print -u2 "taskfile not found: $2"; exit 2 }
shift 2

is_readonly=false; T=300; cwd=""; protocol="$SCRIPT_DIR/../protocol.md"; use_continue=false
out_file=""; loose_format=false; wait_lock=0; do_retry=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly)     is_readonly=true ;;
    --timeout)      [[ $# -ge 2 ]] || { print -u2 "--timeout needs a value"; exit 2 }; T=$2; shift ;;
    --cwd)          [[ $# -ge 2 ]] || { print -u2 "--cwd needs a value"; exit 2 }; cwd=$2; shift ;;
    --protocol)     [[ $# -ge 2 ]] || { print -u2 "--protocol needs a value"; exit 2 }; protocol=$2; shift ;;
    --no-protocol)  protocol="" ;;
    --continue)     use_continue=true ;;
    --out)          [[ $# -ge 2 ]] || { print -u2 "--out needs a value"; exit 2 }; out_file=$2; shift ;;
    --loose-format) loose_format=true ;;
    --wait-lock)    [[ $# -ge 2 ]] || { print -u2 "--wait-lock needs a value"; exit 2 }; wait_lock=$2; shift ;;
    --retry)        [[ $# -ge 2 ]] || { print -u2 "--retry needs a value"; exit 2 }; do_retry=$2; shift ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ "$T" =~ ^[1-9][0-9]*$ ]] || T=300
[[ "$wait_lock" =~ ^[0-9]+$ ]] || wait_lock=0
[[ "$do_retry" == 0 || "$do_retry" == 1 ]] || do_retry=1
# 显式指定的协议文件必须存在;默认路径缺失视为"本仓不完整",同样拒绝静默降级
if [[ -n "$protocol" && ! -f "$protocol" ]]; then
  print -u2 "protocol file not found: $protocol(无契约执行是假绿温床;探针场景用 --no-protocol)"
  exit 2
fi

# --out 路径立即绝对化(opencode 分支会 cd,之后再解析就错了);并杀掉上一轮遗留文件(B11)
if [[ -n "$out_file" ]]; then
  out_file=${out_file:a}
  [[ -d "${out_file:h}" ]] || { print -u2 "--out directory not found: ${out_file:h}"; exit 2 }
  rm -f "$out_file"
fi

# 组装 prompt = 协议前缀 + 任务卡
protocol_injected=false
prompt=$(<"$taskfile")
if [[ -n "$protocol" ]]; then
  prompt="$(<"$protocol")"$'\n\n---\n\n'"$prompt"
  protocol_injected=true
fi

# 任务 id(派生自 .../tasks/TASK-<id>.md;probe 场景无 → null)
task_id=$(print -r -- "$taskfile" | sed -nE 's|.*/tasks/TASK-(.+)\.md$|\1|p')
if [[ -n "$task_id" ]]; then task_id_json="\"$task_id\""; else task_id_json=null; fi

# 任务卡「仓库:」声明 vs --cwd 一致性(B6 曾记录误导性 cwd;不一致只警告不阻断,codex 可按卡内绝对路径干活)
repo_mismatch=null
repo_decl=$(grep -m1 -E '^仓库[::]' "$taskfile" | sed -E 's/^仓库[::][[:space:]]*//; s/[[:space:]]*$//')
if [[ -n "$repo_decl" && -n "$cwd" && "$repo_decl" != "$cwd" ]]; then
  repo_mismatch="\"card=$repo_decl cwd=$cwd\""
fi

# 各家命令组装(姿势差异全部封装在这里)
cmd=()
case "$agent" in
  grok)
    cmd=("$GROK_BIN" -p "$prompt")
    [[ "$is_readonly" == true ]] && cmd+=(--tools read_file,grep,list_dir --max-turns 15)
    [[ "$use_continue" == true ]] && cmd+=(-c)
    [[ -n "$cwd" ]] && cmd+=(--cwd "$cwd")
    ;;
  codex)
    [[ "$use_continue" == true ]] && { print -u2 "--continue not supported for codex(exec resume 未封装)"; exit 2 }
    cmd=("$CODEX_BIN" exec --skip-git-repo-check)
    [[ "$is_readonly" == true ]] && cmd+=(-s read-only)
    [[ -n "$cwd" ]] && cmd+=(--cd "$cwd")
    cmd+=("$prompt")
    ;;
  opencode)
    cmd=("$OPENCODE_BIN" run)
    [[ "$is_readonly" == true ]] && cmd+=(--agent plan)
    [[ "$use_continue" == true ]] && cmd+=(-c)
    cmd+=("$prompt")
    if [[ -n "$cwd" ]]; then
      cd "$cwd" || { print -u2 "cwd not found: $cwd"; exit 2 }   # cd 失败绝不能静默继续:写码会改错目录,评审会审错仓库
    fi
    ;;
  *) print -u2 "unknown agent: $agent (grok|codex|opencode)"; exit 2 ;;
esac

# ── agent 锁:同 agent 并发派发互斥(A9) ──────────────────────────────────────
# mkdir 原子抢锁;持有人活着=busy(快速失败,可 --wait-lock 等待);死了=陈旧锁回收再抢。
# ⚠️ pid 必须由本进程(脚本主体)写:子 shell 里 $$ 是父进程 PID(实测坑)。
# ⚠️ 只删确认无人持有的锁,绝不猜所有权(ruflo 锁纪律)。
LOCKS="$ACOWORK_STATE_DIR/locks"
mkdir -p "$LOCKS" 2>/dev/null
LOCKDIR="$LOCKS/$agent"
BUSY_PID=""
errlog=""; outtmp=""
acquire_lock() {
  local waited=0 steals=0 pid mt now
  while true; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      print -r -- $$ > "$LOCKDIR/pid"
      return 0
    fi
    pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      if (( waited >= wait_lock )); then BUSY_PID=$pid; return 3; fi
      sleep 1; waited=$((waited+1)); continue
    fi
    if [[ -z "$pid" ]]; then
      # 刚 mkdir 还没写 pid 的活锁(极小窗口):5 秒内视为 busy,不抢
      mt=$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0); now=$(date +%s)
      if (( now - mt < 5 )); then
        if (( waited >= wait_lock )); then BUSY_PID="(acquiring)"; return 3; fi
        sleep 1; waited=$((waited+1)); continue
      fi
    fi
    steals=$((steals+1))
    if (( steals > 3 )); then BUSY_PID="${pid:-unknown}"; return 3; fi
    rm -rf "$LOCKDIR"
  done
}
release_lock() {
  [[ -n "${LOCKDIR:-}" ]] || return 0
  local pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
  [[ "$pid" == "$$" ]] && rm -rf "$LOCKDIR"
  return 0
}
trap 'release_lock; [[ -n "$errlog" ]] && rm -f "$errlog"; [[ -n "$outtmp" ]] && rm -f "$outtmp"' EXIT

# ── 执行 ────────────────────────────────────────────────────────────────────
# 派发:进程组超时(超时杀整组,防 CLI 子进程在判定失败后继续改仓库),stdout 落文件
# (B13:命令替换的管道会被 setsid 逃逸的孙进程持有,$(...) 等管道关闭可拖到 T+646s;文件捕获实测 20s→0s)
run_with_timeout() {
  perl -e '
    my $t = shift;                 # 必须在 fork 前取出,否则子进程 exec 的第一个参数是超时秒数
    setpgrp(0,0) or exit 127;
    my $pid = fork();
    if (!$pid) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub {
      kill "TERM", -$pid; select(undef,undef,undef,2); kill "KILL", -$pid; exit 142   # TERM 先让写入 finalize,2s 后 KILL
    };
    alarm $t;
    my $st = waitpid($pid,0);
    exit ($st == -1 ? 142 : ($? >> 8 ? $? >> 8 : ($? & 127 ? 128 + ($? & 127) : 0)));
  ' "$@"
}
errlog=$(mktemp /tmp/acowork-dispatch.XXXXXX)
outtmp=$(mktemp /tmp/acowork-out.XXXXXX)
code=1; duration=0; out=""

run_once() {
  start=$SECONDS
  run_with_timeout "$T" "${cmd[@]}" </dev/null >"$outtmp" 2>"$errlog"
  code=$?
  duration=$((SECONDS - start))
  out=$(<$outtmp)
}

# 实质内容门禁谓词(B12;判据在 2026-09-29 七份真实评审上验证:5 真全放行/幽灵+计划书全拦)
has_substance() {
  local s=$1
  [[ -z "${s//[$' \t\r\n']/}" ]] && return 1
  print -r -- "$s" | grep -q '回声确认' && return 0
  print -r -- "$s" | grep -qE '已检查维度|零发现|无发现' && return 0
  print -r -- "$s" | grep -qE 'P[012]([^0-9A-Za-z]|$)|"severity"|"issue_type"|"finding"' && return 0
  print -r -- "$s" | grep -qE '^\| *[0-9]+ *\|' && return 0
  return 1
}

# ok 判定与原因归类分离;归类顺序:超时/信号(退出码确定)> 关键词(文本猜测)> 其他
classify() {
  ok=false; err=""
  if [[ "$code" -eq 0 && -n "${out//[$' \t\r\n']/}" ]]; then
    if [[ "$protocol_injected" == true && "$loose_format" == false ]] && ! has_substance "$out"; then
      err="回包无实质内容(疑似计划书或截断)"
    else
      ok=true
    fi
  else
    if [[ "$code" -ge 128 ]]; then
      err="超时或被信号终止(>${T}s,code=$code),chars=${#out}"
    elif { print -r -- "$out"; cat "$errlog"; } | grep -qiE 'usage limit|quota|rate.?limit|(^|[^0-9])429([^0-9]|$)'; then
      err="额度/限流"
    elif [[ "$code" -ne 0 ]]; then
      err="退出码 $code"
    else
      err="空回复"
    fi
  fi
}

attempts=1
ok=false; err=""
acquire_lock
if [[ $? -eq 3 ]]; then
  # busy:并发冲突不是瞬态失败,不重试(等锁或改派由主持者决定)
  err="busy(并发派发中,pid=$BUSY_PID;--wait-lock 等待或改派别家)"
  duration=0; code=1; out=""
else
  run_once; classify
  # 瞬态失败自动重试一次(空回复/无实质内容;额度与超时不重试)
  if [[ "$ok" == false && "$do_retry" == 1 ]] && [[ "$err" == "空回复" || "$err" == "回包无实质内容"* ]]; then
    attempts=2
    run_once; classify
  fi
fi

# ── 收尾:--out 落盘 / state.json 推进 / meta / 日志 ─────────────────────────
if [[ "$ok" == true ]]; then
  if [[ -n "$out_file" ]]; then
    print -r -- "$out" > "${out_file}.tmp.$$" && mv "${out_file}.tmp.$$" "$out_file"
  fi
else
  [[ -n "$out_file" ]] && rm -f "$out_file"
fi

# state.json 自动推进(治 P1:状态机从"靠主持者记得写"变成派发副作用;flock 防并行派发互踩)
if [[ "$task_id_json" != null ]]; then
  python3 - "$taskfile" "$agent" "$([[ "$ok" == true ]] && echo ok || echo failed)" "$attempts" <<'PY' 2>/dev/null
import json, sys, os, re, fcntl
taskfile, agent, status, attempt = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
m = re.match(r'^(.*)/tasks/TASK-(.+)\.md$', taskfile)
if not m: sys.exit(0)
work, tid = m.group(1), m.group(2)
sp = os.path.join(work, 'state.json')
if not os.path.exists(sp): sys.exit(0)
lock = open(os.path.join(work, '.state.lock'), 'w')
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    d = json.load(open(sp))
except Exception:
    sys.exit(0)
tasks = d.setdefault('tasks', [])
for t in tasks:
    if t.get('id') == tid and t.get('agent') == agent:
        t['status'] = status; t['attempt'] = max(attempt, int(t.get('attempt') or 0)); break
else:
    tasks.append({'id': tid, 'agent': agent, 'status': status, 'attempt': attempt})
tmp = sp + '.tmp'
json.dump(d, open(tmp, 'w'), ensure_ascii=False)
os.replace(tmp, sp)
PY
fi

if [[ -n "$err" ]]; then jerr="\"$err\""; else jerr=null; fi
jout=null; [[ -n "$out_file" ]] && jout="\"$out_file\""
check=off
if [[ "$protocol_injected" == true ]]; then
  if [[ "$loose_format" == true ]]; then check=loose; else check=substance; fi
fi
meta="{\"agent\":\"$agent\",\"ok\":$ok,\"readonly\":$is_readonly,\"error\":$jerr,\"duration_secs\":$duration,\"chars\":${#out},\"cwd\":\"${cwd:-unset}\",\"protocol_injected\":$protocol_injected,\"task\":$task_id_json,\"attempts\":$attempts,\"out\":$jout,\"check\":\"$check\",\"repo_mismatch\":$repo_mismatch}"

print -r -- "$out"
print -u2 -- "$meta"
# 任务卡派发自动留痕(取代旧版 host 侧 2>> 重定向——那会因重定向先建文件而留幽灵日志外的坑,也容易忘)
if [[ "$task_id_json" != null ]]; then
  print -r -- "$meta" >> "${taskfile:h:h}/dispatch.log" 2>/dev/null
fi

if [[ "$ok" == true ]]; then exit 0; else exit 1; fi
