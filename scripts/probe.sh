#!/bin/zsh
# acowork 可用性探测:对 grok/codex/opencode 各发一个最小探针
# 不可用(额度耗尽/限流/超时/环境错误)即摘除,输出 JSON roster 供编排用。
#
# v2:不再自带 CLI 姿势/超时/归因逻辑——探针直接走 dispatch.sh(单源),
#     自身只做三件事:并行编排、行锚 PONG 判定、roster 汇总。
#     探针带只读锁并在空目录执行(探测存活不需要任何写权限面)。
# v3(2026-09-29):busy≠死亡——探测失败若归因 busy(该 agent 正被并发派发,
#     dispatch agent 锁快速失败),判「可用,占用中」而不是摘除(实测:grok 正在
#     另一会话跑 214s 评审,probe 误报"退出码1"导致整轮丢失深审员)。
#
# 用法:zsh probe.sh [超时秒数,默认120]
# 输出:stderr=人类可读表格;stdout 最后一段为 JSON(roster)
# 退出码:0=至少一家可用;1=全部不可用;2=脚本自身错误

set -u
T=${1:-120}
[[ "$T" =~ ^[1-9][0-9]*$ ]] || T=120
readonly SCRIPT_DIR=${0:A:h}
[[ -f "$SCRIPT_DIR/dispatch.sh" ]] || { print -u2 "dispatch.sh not found next to probe.sh"; exit 2 }

W=$(mktemp -d /tmp/acowork-probe.XXXXXX) || exit 2
trap 'rm -rf "$W" "$PROBE_DIR"' EXIT
PROBE_DIR=$(mktemp -d /tmp/acowork-probe-cwd.XXXXXX)   # 空目录:探针不碰目标仓库,不加载仓库指令

print -r -- 'Reply with exactly: PONG-OK' > "$W/probe-task.md"

probe_one() {
  local agent=$1
  # --retry 0:探针不自动重试(空回复重试会把死 agent 的探测时间翻倍;摘除前重探由 A4 流程管)
  zsh "$SCRIPT_DIR/dispatch.sh" "$agent" "$W/probe-task.md" \
    --no-protocol --readonly --cwd "$PROBE_DIR" --timeout "$T" --retry 0 \
    > "$W/$agent.out" 2> "$W/$agent.meta"
  echo $? > "$W/$agent.code"
}

probe_one grok      &
probe_one codex     &
probe_one opencode  &
wait

# 判定:dispatch 退出码 0 且输出含「行锚定」PONG-OK(行锚防 prompt 回显假阳性)
judge() {
  local name=$1 code reason meta_err
  code=$(<"$W/$name.code")
  if [[ "$code" -eq 0 ]] && grep -qi '^PONG-OK[[:space:]]*$' "$W/$name.out"; then
    reason='OK'
  else
    # 复用 dispatch 的归因(单源;仅当 dispatch 未给归因时兜底)
    meta_err=$(grep -o '"error":"[^"]*"' "$W/$name.meta" 2>/dev/null | head -1 | sed 's/"error":"//; s/"$//')
    if [[ "$code" -eq 2 ]]; then
      reason="用法错误(${meta_err:-see dispatch})"
    elif [[ -n "$meta_err" && "$meta_err" != "null" ]]; then
      reason="$meta_err"
    elif [[ "$code" -ne 0 ]]; then
      reason="退出码 $code"
    else
      reason="无有效回复"
    fi
  fi

  local avail
  # busy ≠ 死亡:该 agent 正被并发派发(dispatch 锁快速失败)→ 判可用,占用中
  if [[ "$reason" == 'OK' || "$reason" == busy* ]]; then
    avail=true
    [[ "$reason" == busy* ]] && reason="$reason;视为可用(占用中)"
  else
    avail=false
  fi
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
print -u2 -- "=== acowork 探测结果($(date '+%H:%M:%S'))==="
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
