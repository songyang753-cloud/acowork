#!/bin/zsh
# council 可用性探测:对 grok/codex/opencode 各发一个最小探针
# 不可用(额度耗尽/限流/超时/环境错误)即摘除,输出 JSON roster 供编排用。
# 用法:zsh probe.sh [超时秒数,默认90]
# 输出:stderr=人类可读表格;stdout 最后一段为 JSON(roster)
# 退出码:0=至少一家可用;1=全部不可用;2=脚本自身错误
#
# 判定原则(经 grok 交叉评审修订):
#   ok = 退出码==0 且输出含成功标记 —— 错误关键词只归类原因,不参与 ok 判定
#   (否则评审文本里提到 "quota" 之类的词会把成功回包误杀)

set -u
T=${1:-90}
[[ "$T" =~ ^[1-9][0-9]*$ ]] || T=90   # 非正整数回退默认,防 alarm 0 挂死
W=$(mktemp -d /tmp/council-probe.XXXXXX) || exit 2
trap 'rm -rf "$W"' EXIT

# perl alarm 实现 macOS 下的超时(exec 后同 PID 收 SIGALRM;exec 失败必须 or exit 127,否则 perl 默认 exit 0 洗成"跑完了")
run_probe() {
  local name=$1; shift
  ( perl -e 'alarm shift; exec @ARGV or exit 127' "$T" "$@" </dev/null >"$W/$name.out" 2>&1 )
  echo $? >"$W/$name.code"
}

run_probe grok      "$HOME/.grok/bin/grok" -p 'Reply with exactly: PONG-OK' &
run_probe codex     /opt/homebrew/bin/codex exec --skip-git-repo-check 'Reply with exactly: PONG-OK' &
run_probe opencode  "$HOME/.opencode/bin/opencode" run 'Reply with exactly: PONG-OK' &
wait

# ok 判定与原因归类分离;成功=退出码0 且输出含「行锚定」的 PONG-OK(行锚防 prompt 回显假阳性,大小写不敏感防变体)
judge() {
  local name=$1 code out reason
  if [[ -f "$W/$name.code" ]]; then
    code=$(<"$W/$name.code")
  else
    code=999   # job 未及写状态即被杀
  fi
  out=$(<"$W/$name.out" 2>/dev/null) || out=''

  if [[ "$code" -eq 0 ]] && print -r -- "$out" | grep -qi '^PONG-OK[[:space:]]*$'; then
    reason='OK'
  elif [[ "$code" -eq 999 ]]; then
    reason='job状态丢失(外部信号/SIGKILL?)'
  elif [[ "$code" -ge 128 ]]; then
    reason="超时或被信号终止(>${T}s,code=$code)"
  elif print -r -- "$out" | grep -qiE 'usage limit|quota|rate.?limit|(^|[^0-9])429([^0-9]|$)'; then
    reason='额度/限流'
  elif [[ "$code" -ne 0 ]]; then
    reason="退出码 $code"
  else
    reason="无有效回复"
  fi

  local avail
  [[ "$reason" == 'OK' ]] && avail=true || avail=false
  print -r -- "$name|$avail|$reason"
}

RESULTS=""
AVAILABLE_COUNT=0
for agent in grok codex opencode; do
  line=$(judge "$agent")
  RESULTS+="$line"$'\n'
  avail=${${line#*|}%%|*}
  [[ "$avail" == "true" ]] && AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
done

# 人类可读表格 → stderr(for 循环直读变量,不走管道:print -u2 接不进 pipe)
print -u2 -- "=== council 探测结果($(date '+%H:%M:%S'))==="
for line in ${(f)RESULTS}; do
  name=${line%%|*}; rest=${line#*|}; avail=${rest%%|*}; reason=${rest#*|}
  [[ "$avail" == "true" ]] && mark="✅" || mark="❌"
  print -u2 -- "$mark $name: $reason"
done
print -u2 -- "可用 $AVAILABLE_COUNT/3"

# JSON roster → stdout(编排者解析这个;reason 做最小转义)
json_escape() { print -r -- "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ' | sed -e 's/ *$//' }
print -n '{"timestamp":"'$(date '+%Y-%m-%dT%H:%M:%S%z')'","agents":{'
first=true
for line in ${(f)RESULTS}; do
  name=${line%%|*}; rest=${line#*|}; avail=${rest%%|*}; reason=$(json_escape "${rest#*|}")
  $first || print -n ','
  first=false
  print -n "\"$name\":{\"available\":$avail,\"reason\":\"$reason\"}"
done
print '},"available_count":'$AVAILABLE_COUNT'}'

[[ "$AVAILABLE_COUNT" -gt 0 ]] && exit 0 || exit 1
