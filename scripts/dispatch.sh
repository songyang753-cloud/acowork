#!/bin/zsh
# acowork 统一派活器:把任务卡派给指定 agent,封装各家 CLI 姿势差异。
# 主持者只用这一个入口派活,不需要记住每家的坑。
#
# 用法: dispatch.sh <grok|codex|opencode> <taskfile> [选项]
# 选项:
#   --readonly       评审模式:物理只读锁(grok=工具白名单/codex=read-only沙箱/opencode=plan agent)
#   --timeout <秒>   默认 300
#   --cwd <dir>      执行目录(写码任务传目标仓库),默认当前目录
#   --protocol <f>   协议文件前缀注入,默认脚本同目录 ../protocol.md;--no-protocol 跳过
#   --continue       续最近会话(opencode:-c / grok:-c;codex:exec resume 暂不封装)
#
# 输出:回包正文 → stdout(主持者重定向到 replies/);一行 JSON 元信息 → stderr
# 退出码:0=成功 1=agent失败(超时/额度/空回复)2=用法错误
#
# ok 判定原则(经 grok 交叉评审修订):
#   ok = 退出码==0 且输出非空 —— 错误关键词只归类原因,不参与 ok 判定
#   (否则评审文本里提到 "quota" 之类的词会把成功回包误杀,实测踩过)

set -u
readonly SCRIPT_DIR=${0:A:h}

agent=$1; taskfile=$2
[[ -f "$taskfile" ]] || { print -u2 "taskfile not found: $taskfile"; exit 2 }
shift 2

is_readonly=false; T=300; cwd=""; protocol="$SCRIPT_DIR/../protocol.md"; use_continue=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly)    is_readonly=true ;;
    --timeout)     T=$2; shift ;;
    --cwd)         cwd=$2; shift ;;
    --protocol)    protocol=$2; shift ;;
    --no-protocol) protocol="" ;;
    --continue)    use_continue=true ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[[ "$T" =~ ^[1-9][0-9]*$ ]] || T=300

# 组装 prompt = 协议前缀 + 任务卡
prompt=$(<"$taskfile")
if [[ -n "$protocol" && -f "$protocol" ]]; then
  prompt="$(<"$protocol")"$'\n\n---\n\n'"$prompt"
fi

# 各家命令组装(姿势差异全部封装在这里)
cmd=()
case "$agent" in
  grok)
    cmd=("$HOME/.grok/bin/grok" -p "$prompt")
    [[ "$is_readonly" == true ]] && cmd+=(--tools read_file,grep,list_dir --max-turns 15)
    [[ "$use_continue" == true ]] && cmd+=(-c)
    [[ -n "$cwd" ]] && cmd+=(--cwd "$cwd")
    ;;
  codex)
    cmd=(/opt/homebrew/bin/codex exec --skip-git-repo-check)
    [[ "$is_readonly" == true ]] && cmd+=(-s read-only)
    [[ -n "$cwd" ]] && cmd+=(--cd "$cwd")
    cmd+=("$prompt")
    ;;
  opencode)
    cmd=("$HOME/.opencode/bin/opencode" run)
    [[ "$is_readonly" == true ]] && cmd+=(--agent plan)
    [[ "$use_continue" == true ]] && cmd+=(-c)
    [[ -n "$cwd" ]] && cd "$cwd"
    cmd+=("$prompt")
    ;;
  *) print -u2 "unknown agent: $agent (grok|codex|opencode)"; exit 2 ;;
esac

# 派发(带超时,macOS 无 timeout 命令,用 perl alarm;stderr 分离捕捉用于归类)
errlog=$(mktemp /tmp/acowork-dispatch.XXXXXX)
start=$SECONDS
out=$(perl -e 'alarm shift; exec @ARGV or exit 127' "$T" "${cmd[@]}" </dev/null 2>"$errlog")
code=$?
duration=$((SECONDS - start))

# ok 判定与原因归类分离;归类顺序:超时(退出码确定)> 关键词(文本猜测)> 其他
ok=false; err=""
if [[ "$code" -eq 0 && -n "${out//[$' \t\r\n']/}" ]]; then
  ok=true
else
  if [[ "$code" -ge 128 ]]; then
    err="超时或信号终止(>${T}s),chars=${#out}"
  elif { print -r -- "$out"; cat "$errlog"; } | grep -qiE 'usage limit|quota|rate.?limit|(^|[^0-9])429([^0-9]|$)'; then
    err="额度/限流"
  elif [[ "$code" -ne 0 ]]; then
    err="退出码 $code"
  else
    err="空回复"
  fi
fi
rm -f "$errlog"

print -r -- "$out"
print -u2 "{\"agent\":\"$agent\",\"ok\":$ok,\"readonly\":$is_readonly,\"error\":\"${err:-null}\",\"duration_secs\":$duration,\"chars\":${#out}}"
$ok && exit 0 || exit 1
