#!/bin/zsh
# acowork 脚本行为测试:用假 CLI(经 *_BIN 环境变量注入)覆盖 dispatch/probe 的关键判定分支。
# bad-cases B 类每条教训对应一个用例;跑法:zsh test.sh,全绿 exit 0。
set -u
readonly SCRIPT_DIR=${0:A:h}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); print -r -- "  ✅ $1" }
bad()  { FAIL=$((FAIL+1)); print -r -- "  ❌ $1" }
check(){ if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi }

# ---- 假 CLI:按 FAKE_MODE 模拟各家行为(忽略真实参数) ----
FAKE=$(mktemp -d /tmp/acowork-test.XXXXXX)
trap 'rm -rf "$FAKE"' EXIT
cat > "$FAKE/cli" <<'EOF'
#!/bin/sh
case "$FAKE_MODE" in
  ok)      printf 'PONG-OK\n'; exit 0 ;;
  quota)   printf "ERROR: You've hit your usage limit\n" >&2; exit 1 ;;
  timeout) sleep 30 ;;
  empty)   exit 0 ;;
  w1429)   printf 'latency 1429ms ok\nPONG-OK\n'; exit 0 ;;
  dump)    printf '%s\n' "$@" > "$FAKE_ARGS_FILE"; printf 'PONG-OK\n'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKE/cli"
# 按 agent 注入不同行为的包装脚本(probe 三探针并行,单 FAKE_MODE 区分不了)
mk() { printf '#!/bin/sh\nFAKE_MODE=%s exec "%s/cli" "$@"\n' "$2" "$FAKE" > "$FAKE/$1"; chmod +x "$FAKE/$1"; }
mk ok ok; mk quota quota; mk timeout timeout; mk empty empty; mk w1429 w1429; mk dump dump
# dispatch 单测默认走假 CLI;行为模式由包装脚本名决定(包装内部硬编码,外部 FAKE_MODE 传不进去)
export GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/ok" OPENCODE_BIN="$FAKE/ok"

TASK=$(mktemp); print -r -- 'test task' > "$TASK"
D() { local mode=$1 extra=${2:-}; OPENCODE_BIN="$FAKE/$mode" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" ${=extra} >"$FAKE/out" 2>"$FAKE/meta"; echo $?; }

print -- "== dispatch.sh 判定分支 =="
check "正常回包:exit 0 + ok:true" '[[ $(D ok) -eq 0 ]] && grep -q "\"ok\":true" "$FAKE/meta"'
check "成功时 error 为 JSON null(非字符串\"null\")" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; grep -q "\"error\":null" "$FAKE/meta"'
check "额度耗尽:exit 1 + 归因额度/限流(B1)" '[[ $(D quota) -eq 1 ]] && grep -q "额度/限流" "$FAKE/meta"'
check "超时:exit 1 + 归因超时且进程组被杀(B2/B8)" '[[ $(D timeout "--timeout 2") -eq 1 ]] && grep -q "超时" "$FAKE/meta"'
check "空回复:exit 1 + 归因空回复" '[[ $(D empty) -eq 1 ]] && grep -q "空回复" "$FAKE/meta"'
check "429 词边界:正文含 1429 不误杀(B4)" '[[ $(D w1429) -eq 0 ]]'
check "--cwd 不存在:exit 2 不静默(S1)" '[[ $(D ok "--cwd /nonexistent-dir-xyz") -eq 2 ]]'
check "--protocol 不存在:exit 2 拒绝无契约执行" '[[ $(D ok "--protocol /nonexistent.md") -eq 2 ]]'
check "codex 传 --continue:显式 exit 2" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" codex "$TASK" --continue >/dev/null 2>&1; [[ $? -eq 2 ]]'
check "成功时元信息含 cwd 与 protocol_injected" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; grep -q "protocol_injected" "$FAKE/meta" && grep -q "\"cwd\"" "$FAKE/meta"'
export FAKE_ARGS_FILE="$FAKE/args.txt"
check "参数契约:prompt 必须真的传给 CLI(重写丢参数的回归,B10)" 'OPENCODE_BIN="$FAKE/dump" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>&1; grep -q "test task" "$FAKE/args.txt"'

print -- "== probe.sh roster(三家假 CLI 各异) =="
P1=$(GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/quota" OPENCODE_BIN="$FAKE/ok" zsh "$SCRIPT_DIR/probe.sh" 15 2>/dev/null)
check "probe 摘除额度耗尽者(2/3 可用,归因传递)" 'echo "$P1" | grep -q "\"codex\":{.*\"available\":false.*额度" && echo "$P1" | grep -q "\"available_count\":2"'
check "全员不可用:probe exit 1" 'GROK_BIN="$FAKE/quota" CODEX_BIN="$FAKE/quota" OPENCODE_BIN="$FAKE/quota" zsh "$SCRIPT_DIR/probe.sh" 15 >/dev/null 2>&1; [[ $? -eq 1 ]]'
P3=$(GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/ok" OPENCODE_BIN="$FAKE/timeout" zsh "$SCRIPT_DIR/probe.sh" 5 2>/dev/null)
check "probe 超时归因传递(2/3)" 'echo "$P3" | grep -q "超时" && echo "$P3" | grep -q "\"available_count\":2"'

print -- "== 结果 =="
print -r -- "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
