#!/bin/zsh
# acowork 脚本行为测试:用假 CLI(经 *_BIN 环境变量注入)覆盖 dispatch/probe/work/gate 的关键判定分支。
# 原则:失效清单驱动——每个用例名对应一个真实踩过的失效形态(bad-cases.md 的 🌱 编号)。
# 跑法:zsh test.sh,全绿 exit 0。
# 隔离:ACOWORK_STATE_DIR 指向测试沙箱,不碰真实 ~/.local/state/acowork(锁/注册表零污染)。

set -u
readonly SCRIPT_DIR=${0:A:h}
export ACOWORK_STATE_DIR=$(mktemp -d /tmp/acowork.teststate.XXXXXX)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); print -r -- "  ✅ $1" }
bad()  { FAIL=$((FAIL+1)); print -r -- "  ❌ $1  [$2]" }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi }

# ---- 假 CLI:按 FAKE_MODE 模拟各家行为(忽略真实参数) ----
FAKE=$(mktemp -d /tmp/acowork.test.XXXXXX)
export FAKE_DIR="$FAKE"
trap 'rm -rf "$FAKE" "$ACOWORK_STATE_DIR"; pkill -f "acowork-holder" 2>/dev/null' EXIT
cat > "$FAKE/cli" <<'EOF'
#!/bin/sh
case "$FAKE_MODE" in
  ok)      printf 'PONG-OK\n'; exit 0 ;;
  quota)   printf "ERROR: You've hit your usage limit\n" >&2; exit 1 ;;
  timeout) sleep 30 ;;
  empty)   exit 0 ;;
  w1429)   printf 'latency 1429ms ok\nPONG-OK\n'; exit 0 ;;
  dump)    printf '%s\n' "$@" > "$FAKE_ARGS_FILE"; printf 'PONG-OK\n'; exit 0 ;;
  # ── v1.4 内容门禁用例 ──
  stub)    printf "I'll take TASK-R1 as a worker: first load the acowork protocol and the review inputs, then systematically audit all 260 cases across the seven dimensions.I'll write a structured audit script over the 260-row batch, then manually judge the ambiguous matching cases.I'll use the browser runtime to load and analyze the full 260-row batch programmatically.\n"; exit 0 ;;
  jsonrev) printf '{"row_index":1,"severity":"P1","issue_type":"R2匹配","description":"播客agent误分","suggestion":"改短音频"}\n'; exit 0 ;;
  flaky)   n=$(cat "$FAKE_DIR/flaky.count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$FAKE_DIR/flaky.count"
           if [ "$n" -ge 2 ]; then printf '## 回声确认\n复审通过\n'; exit 0; else exit 0; fi ;;
esac
exit 1
EOF
chmod +x "$FAKE/cli"
# 按 agent 注入不同行为的包装脚本(probe 三探针并行,单 FAKE_MODE 区分不了)
mk() { printf '#!/bin/sh\nFAKE_MODE=%s exec "%s/cli" "$@"\n' "$2" "$FAKE" > "$FAKE/$1"; chmod +x "$FAKE/$1"; }
mk ok ok; mk quota quota; mk timeout timeout; mk empty empty; mk w1429 w1429; mk dump dump
mk stub stub; mk jsonrev jsonrev; mk flaky flaky
export GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/ok" OPENCODE_BIN="$FAKE/ok"

TASK=$(mktemp); print -r -- 'test task' > "$TASK"
# D():基础判定分支测试统一带 --loose-format(这些用例只测 ok/归因,不测内容门禁)
D() { local mode=$1 extra=${2:-}; OPENCODE_BIN="$FAKE/$mode" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --loose-format ${=extra} >"$FAKE/out" 2>"$FAKE/meta"; echo $?; }

print -- "== dispatch.sh 判定分支(旧 14 用例) =="
check "正常回包:exit 0 + ok:true" '[[ $(D ok) -eq 0 ]] && grep -q "\"ok\":true" "$FAKE/meta"'
check "成功时 error 为 JSON null(非字符串\"null\")" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --loose-format >/dev/null 2>"$FAKE/meta"; grep -q "\"error\":null" "$FAKE/meta"'
check "额度耗尽:exit 1 + 归因额度/限流(B1)" '[[ $(D quota) -eq 1 ]] && grep -q "额度/限流" "$FAKE/meta"'
check "超时:exit 1 + 归因超时且进程组被杀(B2/B8)" '[[ $(D timeout "--timeout 2") -eq 1 ]] && grep -q "超时" "$FAKE/meta"'
check "空回复:exit 1 + 归因空回复" '[[ $(D empty) -eq 1 ]] && grep -q "空回复" "$FAKE/meta"'
check "429 词边界:正文含 1429 不误杀(B4)" '[[ $(D w1429) -eq 0 ]]'
check "--cwd 不存在:exit 2 不静默(S1)" '[[ $(D ok "--cwd /nonexistent-dir-xyz") -eq 2 ]]'
check "--protocol 不存在:exit 2 拒绝无契约执行" '[[ $(D ok "--protocol /nonexistent.md") -eq 2 ]]'
check "codex 传 --continue:显式 exit 2" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" codex "$TASK" --continue >/dev/null 2>&1; [[ $? -eq 2 ]]'
check "成功时元信息含 cwd 与 protocol_injected" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --loose-format >/dev/null 2>"$FAKE/meta"; grep -q "protocol_injected" "$FAKE/meta" && grep -q "\"cwd\"" "$FAKE/meta"'
export FAKE_ARGS_FILE="$FAKE/args.txt"
check "参数契约:prompt 必须真的传给 CLI(B10)" 'OPENCODE_BIN="$FAKE/dump" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --loose-format >/dev/null 2>&1; grep -q "test task" "$FAKE/args.txt"'
check "cwd 字段记录 --cwd 参数本身而非 shell pwd(修 P9 误导)" 'FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$TASK" --loose-format --cwd "$FAKE" >/dev/null 2>"$FAKE/meta"; grep -q "\"cwd\":\"$FAKE\"" "$FAKE/meta"'
check "任务卡「仓库:」与 --cwd 不一致 → repo_mismatch 警告" 'TM=$(mktemp); print -r -- "仓库: /elsewhere/repo\n正文" > "$TM"; FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$TM" --loose-format --cwd "$FAKE" >/dev/null 2>"$FAKE/meta"; grep -q "repo_mismatch" "$FAKE/meta" && grep -q "/elsewhere/repo" "$FAKE/meta"'
check "任务卡派发 meta 含 task 字段" 'TW=$(mktemp -d /tmp/acowork.gX.XXXXXX)/tasks; mkdir -p "$TW"; cp "$TASK" "$TW/TASK-9.md"; FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$TW/TASK-9.md" --loose-format >/dev/null 2>"$FAKE/meta"; grep -q "\"task\":\"9\"" "$FAKE/meta"'

print -- "== 内容门禁(B12:353 字计划书曾判 ok:true) =="
check "计划书 stub:exit 1 + 归因无实质内容" '[[ $(OPENCODE_BIN="$FAKE/stub" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; echo $?) -eq 1 ]] && grep -q "无实质内容" "$FAKE/meta"'
check "JSON 发现清单正例:门禁放行(B12 反例防误伤)" '[[ $(OPENCODE_BIN="$FAKE/jsonrev" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; echo $?) -eq 0 ]] && grep -q "\"ok\":true" "$FAKE/meta"'
check "--loose-format:一句话 confirm 卡放行" '[[ $(OPENCODE_BIN="$FAKE/stub" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --loose-format >/dev/null 2>&1; echo $?) -eq 0 ]]'
check "空回复自动重试 1 次后成功:attempts=2(治「重试写在文档没人执行」)" 'rm -f "$FAKE/flaky.count"; OPENCODE_BIN="$FAKE/flaky" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; [[ $? -eq 0 ]] && grep -q "\"attempts\":2" "$FAKE/meta"'
check "额度失败不自动重试:attempts=1" 'OPENCODE_BIN="$FAKE/quota" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" >/dev/null 2>"$FAKE/meta"; [[ $? -eq 1 ]] && grep -q "\"attempts\":1" "$FAKE/meta"'

print -- "== --out(B11:失败派发曾留 1 字节幽灵评审文件) =="
check "失败派发:--out 目标不存在(幽灵绝育)" 'OF="$FAKE/reviews/REVIEW-1.md"; mkdir -p "$FAKE/reviews"; touch "$OF"; OPENCODE_BIN="$FAKE/quota" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --out "$OF" >/dev/null 2>&1; [[ $? -eq 1 ]] && [[ ! -e "$OF" ]]'
check "成功派发:--out 写入回包,stdout 同样输出" 'OF="$FAKE/reviews/REVIEW-2.md"; OPENCODE_BIN="$FAKE/jsonrev" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$TASK" --out "$OF" >"$FAKE/out" 2>/dev/null; [[ $? -eq 0 ]] && grep -q "severity" "$OF" && grep -q "severity" "$FAKE/out"'

print -- "== agent 锁(A8/A9:busy 误判死亡 + 并发互踩) =="
# holder:独立脚本进程持锁($$ 由脚本主体写,防「子 shell 里 $$=父进程」坑);每次先清场再持锁
HOLD="$FAKE/acowork-holder.zsh"
print -- "#!/bin/zsh\nmkdir -p \"$ACOWORK_STATE_DIR/locks\"; rm -rf \"$ACOWORK_STATE_DIR/locks/grok\"; mkdir \"$ACOWORK_STATE_DIR/locks/grok\" && print \$\$ > \"$ACOWORK_STATE_DIR/locks/grok/pid\" && sleep 30" > "$HOLD"
chmod +x "$HOLD"
check "活锁:busy 快速失败并给出持锁 pid" 'zsh "$HOLD" & H1=$!; sleep 0.5; s=$SECONDS; FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$TASK" --loose-format >/dev/null 2>"$FAKE/meta"; rc=$?; kill $H1 2>/dev/null; wait $H1 2>/dev/null; [[ $rc -eq 1 ]] && grep -q "busy" "$FAKE/meta" && (( SECONDS - s < 10 ))'
check "死锁:持有人消亡后自动回收接管" 'zsh "$HOLD" & H2=$!; sleep 0.5; kill $H2; wait $H2 2>/dev/null; sleep 0.3; FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$TASK" --loose-format >/dev/null 2>"$FAKE/meta"; [[ $? -eq 0 ]]'
check "probe:busy 不判死(available:true + busy 归因)" 'zsh "$HOLD" & H3=$!; sleep 0.5; P=$(GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/ok" OPENCODE_BIN="$FAKE/ok" zsh "$SCRIPT_DIR/probe.sh" 15 2>/dev/null); kill $H3 2>/dev/null; wait $H3 2>/dev/null; echo "$P" | grep -q "\"grok\":{.*\"available\":true.*busy" && echo "$P" | grep -q "\"available_count\":3"'

print -- "== state.json 自动推进(治 P1:状态机永远停在 probe) =="
check "任务卡派发后 tasks[] 自动 upsert(ok)" 'SW=$(mktemp -d /tmp/acowork.gY.XXXXXX); mkdir -p "$SW/tasks"; cp "$TASK" "$SW/tasks/TASK-7.md"; print "{\"phase\":\"probe\",\"tasks\":[],\"requirements\":[]}" > "$SW/state.json"; FAKE_MODE=ok zsh "$SCRIPT_DIR/dispatch.sh" grok "$SW/tasks/TASK-7.md" --loose-format >/dev/null 2>&1; grep -qE "\"id\": *\"7\"" "$SW/state.json" && grep -qE "\"status\": *\"ok\"" "$SW/state.json"'
check "失败派发同样入账(failed)" 'SW2=$(mktemp -d /tmp/acowork.gZ.XXXXXX); mkdir -p "$SW2/tasks"; cp "$TASK" "$SW2/tasks/TASK-8.md"; print "{\"phase\":\"probe\",\"tasks\":[]}" > "$SW2/state.json"; OPENCODE_BIN="$FAKE/quota" zsh "$SCRIPT_DIR/dispatch.sh" opencode "$SW2/tasks/TASK-8.md" >/dev/null 2>&1; grep -qE "\"status\": *\"failed\"" "$SW2/state.json"'

print -- "== work.sh 注册表(A9:全局指针被并发会话覆盖) =="
check "add/list/close 全链" 'W1=$(mktemp -d /tmp/acowork.w1.XXXXXX); zsh "$SCRIPT_DIR/work.sh" add "$W1" "测试轮A" >/dev/null && zsh "$SCRIPT_DIR/work.sh" list --active | grep -q "测试轮A" && zsh "$SCRIPT_DIR/work.sh" close "$W1" done >/dev/null && ! zsh "$SCRIPT_DIR/work.sh" list --active | grep -q "测试轮A"'
check "拒绝注册 /tmp/acowork. 前缀外的路径(防指针污染)" 'zsh "$SCRIPT_DIR/work.sh" add "$HOME" "越界" >/dev/null 2>&1; [[ $? -eq 1 ]]'
check "close 未注册的工作区:报错不静默" 'zsh "$SCRIPT_DIR/work.sh" close /tmp/acowork.never-exist done >/dev/null 2>&1; [[ $? -eq 1 ]]'

print -- "== gate.sh 机器放行门(P10:零门禁→已知缺陷必须全报红) =="
# 坏夹具:每处违规都来自 2026-09-29 真实现场
BW=$(mktemp -d /tmp/acowork.gbad.XXXXXX); mkdir -p "$BW"/{tasks,reviews,replies,verdicts}
print -r -- '{"agent":"grok","ok":true,"task":"R1","out":null}' > "$BW/dispatch.log"
print -r -- '{"agent":"opencode","ok":false,"task":"R2","out":null}' >> "$BW/dispatch.log"
printf '## 回声确认\n| 1 | P1 | a:1 | x | y |\n' > "$BW/reviews/REVIEW-R1-by-grok.md"      # 真评审(通过)
printf '\n' > "$BW/reviews/REVIEW-R2-by-opencode.md"                                        # 1 字节幽灵(B11 现场)
print -r -- '# TASK R1\n仓库: /tmp/x' > "$BW/tasks/TASK-R1.md"
print '{"phase":"probe","tasks":[],"requirements":[]}' > "$BW/state.json"                    # 停在 probe(P1 现场)
print -r -- 'R1: query与上下文逻辑一致' > "$BW/REQUIREMENTS.md"                              # 无 oracle(P2 现场)
print -r -- '{"findings_raw":{"grok":3},"findings_confirmed":5,"agents_used":["grok"]}' > "$BW/ledger.json"  # 5>3(P4 现场)
G_OUT=$(zsh "$SCRIPT_DIR/gate.sh" "$BW" 2>&1); G_RC=$?
check "坏夹具:exit 1 且六类违规逐项报红(G1幽灵/G2内容/G3状态/G4判据/G5账本/G8注册)" '[[ $G_RC -eq 1 ]] && echo "$G_OUT" | grep -q "G1 .*幽灵" && echo "$G_OUT" | grep -q "G3 .*probe" && echo "$G_OUT" | grep -q "G4 .*无 oracle" && echo "$G_OUT" | grep -q "G5 .*findings_confirmed" && echo "$G_OUT" | grep -q "G8 .*未注册"'
check "坏夹具:每条违规带 Fix 行(wshobson doc_gardener 纪律)" '[[ $(echo "$G_OUT" | grep -c "Fix:") -ge 5 ]]'
check "坏夹具 --final:无 ACCEPTANCE 报红(G6/P2 现场)" 'G_OUT2=$(zsh "$SCRIPT_DIR/gate.sh" "$BW" --final 2>&1); echo "$G_OUT2" | grep -q "G6 .*无 ACCEPTANCE"'
# 好夹具:全部合规的 review-only 轮
GW=$(mktemp -d /tmp/acowork.ggood.XXXXXX); mkdir -p "$GW"/{tasks,reviews,replies,verdicts}
RVP="$GW/reviews/REVIEW-R1-by-grok.md"
print -r -- "{\"agent\":\"grok\",\"ok\":true,\"task\":\"R1\",\"out\":\"$RVP\"}" > "$GW/dispatch.log"
printf '## 回声确认\n| 1 | P1 | a:1 | x | y |\n## 已检查维度清单\n全查\n' > "$RVP"
print -r -- '# TASK R1' > "$GW/tasks/TASK-R1.md"
print '{"phase":"review-only","tasks":[{"id":"R1","agent":"grok","status":"ok","attempt":1}],"requirements":[{"id":"R1","status":"done","round":1}]}' > "$GW/state.json"
print -r -- 'R1: 测试集审查 oracle: python3 check.py → 0 failures' > "$GW/REQUIREMENTS.md"
shasum -a 256 "$GW/REQUIREMENTS.md" | cut -d" " -f1 > "$GW/.requirements.sha256"
print -r -- '{"findings_raw":{"grok":3},"findings_confirmed":{"total":2},"agents_used":["grok"],"agents_skipped":[]}' > "$GW/ledger.json"
print -r -- '# ACCEPTANCE 1(review-only)\n发现对账: raw=3 采纳=2 驳回=1 待办=0\n' > "$GW/ACCEPTANCE-1.md"
zsh "$SCRIPT_DIR/work.sh" add "$GW" "好夹具轮" >/dev/null
G_OUT3=$(zsh "$SCRIPT_DIR/gate.sh" "$GW" --final 2>&1); G_RC3=$?
check "好夹具 --final:全绿放行(exit 0)" '[[ $G_RC3 -eq 0 ]]'
check "好夹具:判据被篡改时公证报红(PWF attest 思想)" 'print -r -- "R1: 被放松的判据 oracle: 永远绿" > "$GW/REQUIREMENTS.md"; zsh "$SCRIPT_DIR/gate.sh" "$GW" --final 2>&1 | grep -q "SHA-256 不符"'
check "好夹具:review-only 对账不守恒报红(2+0+0≠3)" 'print -r -- "R1: 测试集审查 oracle: python3 check.py → 0 failures" > "$GW/REQUIREMENTS.md"; print -r -- "# ACCEPTANCE 1(review-only)\n发现对账: raw=3 采纳=1 驳回=1 待办=0\n" > "$GW/ACCEPTANCE-1.md"; zsh "$SCRIPT_DIR/gate.sh" "$GW" --final 2>&1 | grep -q "不守恒"'
check "未知参数显式拒绝(拼错 --final 静默跳过 G6=假绿,冒烟轮 opencode 报的 P1)" 'zsh "$SCRIPT_DIR/gate.sh" "$GW" --finl >/dev/null 2>&1; [[ $? -eq 2 ]]'
check "workspace 不存在时报真实路径而非 shift 后的 \$1(冒烟轮 codex+opencode 双源 P1)" 'E=$(zsh "$SCRIPT_DIR/gate.sh" /tmp/acowork.no-such-ws --final 2>&1); [[ $? -eq 2 ]] && echo "$E" | grep -q "no-such-ws"'
check "仅警告通过时也有绿标(冒烟轮 grok P1:扫绿习惯误判)" 'print -r -- "R1: 测试集审查 oracle: python3 check.py → 0 failures" > "$GW/REQUIREMENTS.md"; print -r -- "# ACCEPTANCE 1(review-only)\n发现对账: raw=3 采纳=2 驳回=1 待办=0\n" > "$GW/ACCEPTANCE-1.md"; rm -f "$GW/.requirements.sha256"; zsh "$SCRIPT_DIR/gate.sh" "$GW" --final 2>&1 | grep -qE "✅ 通过\([0-9]+ 警告"'

print -- "== probe.sh roster(三家假 CLI 各异) =="
P1=$(GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/quota" OPENCODE_BIN="$FAKE/ok" zsh "$SCRIPT_DIR/probe.sh" 15 2>/dev/null)
check "probe 摘除额度耗尽者(2/3 可用,归因传递)" 'echo "$P1" | grep -q "\"codex\":{.*\"available\":false.*额度" && echo "$P1" | grep -q "\"available_count\":2"'
check "全员不可用:probe exit 1" 'GROK_BIN="$FAKE/quota" CODEX_BIN="$FAKE/quota" OPENCODE_BIN="$FAKE/quota" zsh "$SCRIPT_DIR/probe.sh" 15 >/dev/null 2>&1; [[ $? -eq 1 ]]'
P3=$(GROK_BIN="$FAKE/ok" CODEX_BIN="$FAKE/ok" OPENCODE_BIN="$FAKE/timeout" zsh "$SCRIPT_DIR/probe.sh" 5 2>/dev/null)
check "probe 超时归因传递(2/3)" 'echo "$P3" | grep -q "超时" && echo "$P3" | grep -q "\"available_count\":2"'

print -- "== 结果 =="
print -r -- "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
