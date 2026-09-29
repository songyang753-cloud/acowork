# v1.4 设计依据:20 个同类高分仓调研速查(2026-09-29)

> v1.4 的每个机制都不是拍脑袋——本文记录「机制 ↔ 来源仓 ↔ 证据文件」的对应关系,
> 以及所有来源殊途同归的那个元结论。调研方法:按星数选 20 个同类仓(多agent编排/
> 跨模型评审/状态持久化/门禁),4 路并行深挖代码级证据。

## 元结论(四个独立来源给出同一答案)

**「workflow 携带行为,SKILL.md 文本不携带。」**——trailofbits 用 eval 量化证明(Δ+1.00);
superpowers 把记账做成脚本副作用;agent-harness 让状态机由脚本驱动;claudex-loop 把
评审验收做成 schema 校验。acowork 建仓当天四轮真实使用暴露 12 问题,根因全部是
「规则在 prose 里、零机器门禁」。修复方向不是写更多 SKILL.md 规则,是把规则搬进脚本。

## 机制 ↔ 来源

| v1.4 机制 | 来源仓 | 证据 |
|---|---|---|
| state.json 随派发自动推进 | superpowers `task-done`(测试不过=什么都不写);claudex-loop `result.json` 先 running 后终态 | superpowers `skills/executing-plans/scripts/task-done`;claudex `runner.py:313-381` |
| gate.sh 八门+Fix 行 | K-Dense `test_repo_contract.py`(AST 机器强制 prose 规则);wshobson `doc_gardener.py`(漂移检查带 Fix);agent-harness `loop_controller.py`(close 遇 unverified exit 4) | 见各仓 scripts/ |
| 内容门禁(实质标记判据) | claudex-loop JSON schema+verdict 逻辑自洽(grok 无 --json-schema,退化为标记判据);openclaw 完成通知契约 | claudex `runner.py:20-35,112-142` |
| 判据冻结 SHA-256 公证 | planning-with-files `attest-plan.sh`([PLAN TAMPERED] 拒绝) | PWF `scripts/attest-plan.sh` |
| work.sh 注册表(防并发串台) | superpowers sdd-workspace(一计划一工作区,"structurally removes that failure");wshobson agent-teams(每队独立状态目录) | 见各仓 |
| agent 锁 + busy≠死亡 | ruflo 锁纪律成文(不猜所有权、不删他人的锁);claude-squad(Paused≠失败) | ruflo `docs/mcp-audit-retention.md` |
| 账本单位定死+守恒校验 | trailofbits `check_ledger.py`(对机器枚举人口核账,逃生舱也记账) | ToB `plugins/c-review/scripts/` |
| stdout 文件捕获(治超时失控) | claudex-loop(不经命令替换管道,孙进程持管道问题结构性消失) | claudex `runner.py:180-197` |
| 三条硬规则(点名必派发/跳过必点名/汇报必过 gate) | openclaw coding-agent 三句式("do not silently hand-code");trailofbits second-opinion(跳过谁必须点名) | openclaw `skills/coding-agent/SKILL.md` |
| review-only 轻量路径 | ruflo scope guard(编排开销>收益的活不要编排);llm-council(轻量单文件形态);wshobson 渐进披露(正文≤150行) | 见各仓 |
| 出境三档 | nanoclaw isolation-model(一问定档);K-Dense autoskill(redact+dry-run+本地优先);BugHunter scope.py(default-deny) | 见各仓 |
| 置信分级(双源=高置信) | VoltAgent error-coordinator(模式≥2独立来源才算;数字必须自己数出来) | subagents `error-coordinator.md` |
| 失效清单驱动测试 | claudex 23 个假 CLI 测试(用例名=失效形态名);openclaw(自家 skill 过自家扫描器) | claudex `tests/test_runner.py` |

## 同赛道值得继续盯的仓

- **chaseai-yt/claudex-loop**(2.6k★):与 acowork 最同构,四阶段对抗评审+完整机器层,后续演进优先对标
- **obra/superpowers**(292k★):skill 的 TDD 验证方法论(「没看过 agent 失败就不知道 skill 教对了没」)——acowork 的 P3 修复就欠这一步:下次应实测「点名时主持者不再静默 solo」
- **asklokesh/claudeskill-loki-mode**:37 agents/6 swarms 全流程编排,野心最接近的条目
- **planning-with-files**(27k★):Stop hook 物理拦截是 skill 形态做不到、plugin 形态才有的——acowork v1.5 若转 plugin,这是第一候选机制
