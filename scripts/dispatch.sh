#!/bin/zsh
# acowork 统一派活器:把任务卡派给指定 agent,封装各家 CLI 姿势差异。
# 主持者只用这一个入口派活,不需要记住每家的坑。
# probe.sh 也复用本脚本(姿势/超时/归因单源,不双份维护)。
#
# 用法: dispatch.sh <grok|codex|opencode> <taskfile> [选项]
# 选项:
#   --readonly       评审模式:物理只读锁(grok=工具白名单/codex=read-only沙箱/opencode=plan agent)
#   --timeout <秒>   默认 300
#   --cwd <dir>      执行目录(写码任务传目标仓库);目录不存在=用法错误直接退出
#   --protocol <f>   协议文件前缀注入,默认脚本同目录 ../protocol.md;--no-protocol 跳过;
#                    显式指定的文件不存在=用法错误(静默无契约执行是假绿温床)
#   --continue       续最近会话(仅 grok/opencode;codex 不支持,显式报错)
#
# 环境变量(换机器只改这里,测试用它注入假 CLI):
#   GROK_BIN / OPENCODE_BIN / CODEX_BIN
#
# 输出:回包正文 → stdout;一行 JSON 元信息 → stderr(含 ok/error/cwd/protocol_injected)
# 退出码:0=成功 1=agent失败(超时/额度/空回复)2=用法错误
#
# ok 判定原则(经交叉评审修订):
#   ok = 退出码==0 且输出非空 —— 错误关键词只归类原因,不参与 ok 判定
#   (否则评审文本里提到 "quota" 之类的词会把成功回包误杀,实测踩过)

set -u
readonly SCRIPT_DIR=${0:A:h}
GROK_BIN=${GROK_BIN:-$HOME/.grok/bin/grok}
OPENCODE_BIN=${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}
CODEX_BIN=${CODEX_BIN:-/opt/homebrew/bin/codex}

[[ $# -ge 2 ]] || { print -u2 "usage: dispatch.sh <grok|codex|opencode> <taskfile> [options]"; exit 2 }
agent=$1; taskfile=$2
[[ -f "$taskfile" ]] || { print -u2 "taskfile not found: $taskfile"; exit 2 }
shift 2

is_readonly=false; T=300; cwd=""; protocol="$SCRIPT_DIR/../protocol.md"; use_continue=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly)    is_readonly=true ;;
    --timeout)     [[ $# -ge 2 ]] || { print -u2 "--timeout needs a value"; exit 2 }; T=$2; shift ;;
    --cwd)         [[ $# -ge 2 ]] || { print -u2 "--cwd needs a value"; exit 2 }; cwd=$2; shift ;;
    --protocol)    [[ $# -ge 2 ]] || { print -u2 "--protocol needs a value"; exit 2 }; protocol=$2; shift ;;
    --no-protocol) protocol="" ;;
    --continue)    use_continue=true ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ "$T" =~ ^[1-9][0-9]*$ ]] || T=300
# 显式指定的协议文件必须存在;默认路径缺失视为"本仓不完整",同样拒绝静默降级
if [[ -n "$protocol" && ! -f "$protocol" ]]; then
  print -u2 "protocol file not found: $protocol(无契约执行是假绿温床;探针场景用 --no-protocol)"
  exit 2
fi

# 组装 prompt = 协议前缀 + 任务卡
protocol_injected=false
prompt=$(<"$taskfile")
if [[ -n "$protocol" ]]; then
  prompt="$(<"$protocol")"$'\n\n---\n\n'"$prompt"
  protocol_injected=true
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

# 派发:进程组超时(超时杀整组,防 CLI 子进程在判定失败后继续改仓库),stderr 分离捕捉
errlog=$(mktemp /tmp/acowork-dispatch.XXXXXX)
trap 'rm -f "$errlog"' EXIT
run_with_timeout() {
  perl -e '
    my $t = shift;                 # 必须在 fork 前取出,否则子进程 exec 的第一个参数是超时秒数
    setpgrp(0,0) or exit 127;
    my $pid = fork();
    if (!$pid) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub {
      kill "TERM", -$pid; select(undef,undef,undef,2); kill "KILL", -$pid; exit 142
    };
    alarm $t;
    my $st = waitpid($pid,0);
    exit ($st == -1 ? 142 : ($? >> 8 ? $? >> 8 : ($? & 127 ? 128 + ($? & 127) : 0)));
  ' "$@"
}
start=$SECONDS
out=$(run_with_timeout "$T" "${cmd[@]}" </dev/null 2>"$errlog")
code=$?
duration=$((SECONDS - start))
effective_cwd=${${:-$(pwd)}:-unknown}

# ok 判定与原因归类分离;归类顺序:超时/信号(退出码确定)> 关键词(文本猜测)> 其他
ok=false; err=""
if [[ "$code" -eq 0 && -n "${out//[$' \t\r\n']/}" ]]; then
  ok=true
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

print -r -- "$out"
if [[ -n "$err" ]]; then jerr="\"$err\""; else jerr=null; fi
print -u2 "{\"agent\":\"$agent\",\"ok\":$ok,\"readonly\":$is_readonly,\"error\":$jerr,\"duration_secs\":$duration,\"chars\":${#out},\"cwd\":\"$effective_cwd\",\"protocol_injected\":$protocol_injected}"
$ok && exit 0 || exit 1
