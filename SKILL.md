---
name: acowork
description: 本机多 CLI agent 协同工作(Claude 主持,codex/grok/opencode 为同僚)。当用户要「多agent协作/协同工作/大家一起干/一起规划分工/交叉审查/互相review/叫上 codex/grok/opencode/发挥各家优势/团队协作提升交付速度和质量」时使用。核心机制:协议中立化(protocol.md 注入,任何 agent 都能按契约参与)、文件系统即消息总线(共享工作区+状态机,断点可恢复)、探测摘除(没额度的不派活)、跨源交叉评审(避开同源模型盲区)、统一派活器封装全部 CLI 姿势差异、回声确认防理解漂移、裁决制+机器门禁保质量。
---

# acowork:多 CLI Agent 协同(Claude 主持)

> acowork = **a**gent **co**-work:Claude 主持,grok/codex/opencode 是同僚——讨论、分工、交叉质询、裁决,像一支真正的团队。

四个 agent(Claude/codex/grok/opencode)协同交付:讨论规划 → 并行执行 → 交叉评审 → 裁决合并。**Claude 是主持者和最终责任人,不是发号施令的旁观者**——每一步的质量门都由 Claude 亲手把。

## 0. 何时用 / 不用

**用**:中型以上任务要提速(并行执行+流水线评审);单一视角不放心,要跨模型交叉审查;要对抗「检查者共用假设⇒假绿」。
**不用**:琐碎小改(编排开销>收益);涉密内容不许出本机会话(派活 prompt 会出 Claude 上下文);用户赶时间且只要快不要多方视角。

**成本自觉**:每次派活都是真实 token。审批规则:预计单家产出 <200 字的活不派,自己做。

## 1. 一次性准备(每个协作任务开头)

```bash
SKILL=<本skill目录>   # 如 ~/acowork(clone 到哪就是哪)
WORK=$(mktemp -d /tmp/acowork.XXXXXX) && mkdir -p $WORK/{tasks,replies,reviews,verdicts}
echo "$WORK" > /tmp/acowork-work-pointer                  # 断点恢复指针(跨会话找回 WORK)
echo '{"phase":"probe","tasks":[],"requirements":[]}' > $WORK/state.json
echo '{}' > $WORK/ledger.json
zsh $SKILL/scripts/probe.sh 120 > $WORK/roster.json        # 可用性探测,stdout=JSON
```

- roster 里 `available:false` 的 agent,**写码和评审都不派**(用户明确要求)
- 同一任务内复用 roster;跨任务必须重探(额度会变)
- 全员不可用 → 告知用户,Claude 独立完成,不硬演协作

## 2. 状态机与推进(Claude 的主持循环)

```
probe → plan → [confirm] → execute → review → adjudicate → merge → acceptance ──→ done
                                    ↑_____________________|        |                |
                                    |  (裁决采纳→修复卡)  ↑_______|  (未达标→回炉)  └→ done-with-exceptions
```

- 回炉小循环 = **完整链**(回炉产出必须过审);裁决采纳的 P0 未修复前禁止 merge
- 终态只有 `done` 与 `done-with-exceptions`(例外清单交用户裁决)

每步把进度写进 `$WORK/state.json`(最小 schema 见 protocol.md §2:`phase` + `tasks[{id,agent,status,attempt}]` + `requirements[{id,status,round}]`);会话断了从它恢复,跨会话用 `/tmp/acowork-work-pointer` 找回 `$WORK`,别依赖对话记忆。**acceptance 是 done 的唯一放行门**(见 3.6)。

## 3. 各步操作

### 3.1 plan(规划与分工)
- Claude 起草:任务拆分(标注依赖,DAG)、每张任务卡五要素(见 protocol.md §4)、验收标准优先写成可机器验证的
- **冻结需求清单**:把用户原始需求拆成编号条目,每条写明 **oracle(验证命令+期望结果)**,写入 `$WORK/REQUIREMENTS.md`——这是终验对账的唯一基准;验收标准一旦冻结不许放松(做不到就报例外,不许改判据换绿)
- **需求基准须过两道眼**:①向用户复述清单要点请求确认(存在歧义/方向性分歧时必问,不要自作主张转写);②confirm 轮把清单同步给议员过目——防"Claude 转写时漏一条,acceptance 永远看不到"
- **文件边界不重叠**是并行写码的前提;有重叠的排串行;任务卡禁止全仓 formatter/代码生成类操作(共享副作用会污染别家产出)
- 调度四优先级(protocol.md §8):可用性 > 跨源配对 > 特长路由(grok=500k 长上下文+深审,opencode=快,codex=跨源意见)> 负载均衡

### 3.2 confirm(中大任务才做;小任务跳过)
把规划摘要派给每个可用 agent 征一轮意见,任务卡就一句话:「对分工/边界/验收有异议吗?≤100 字,无异议回 LGTM」。**只此一轮**,有价值的意见吸收后由 Claude 裁决定稿,不开自由讨论。

### 3.3 execute + review(统一用 dispatch.sh,永不手拼 CLI 命令)

```bash
# 执行(写码):--cwd 指向目标仓库
zsh $SKILL/scripts/dispatch.sh <agent> $WORK/tasks/TASK-1.md --cwd <目标仓库> \
  > $WORK/replies/REPLY-1.md 2>>$WORK/dispatch.log

# 评审:--readonly 物理只读锁(grok=工具白名单/codex=read-only沙箱/opencode=plan agent);评审同样传 --cwd
zsh $SKILL/scripts/dispatch.sh <agent> $WORK/tasks/TASK-R1.md --readonly --cwd <目标仓库> --timeout 300 \
  > $WORK/reviews/REVIEW-1-by-<agent>.md 2>>$WORK/dispatch.log
```

- dispatch 自动注入 protocol.md 前缀,对方自动知道契约(这就是「大家一起用」:协议在文件里,不在谁的脑子里)
- 多家并行:Bash 并行调用;评审**流水线式**,一家完成即派审
- 评审超时预算 300s(grok 深审实测 107s+);**部分评审结果(超时截断)不得进入裁决**——审全了才算数
- dispatch 失败(exit 1)看 stderr JSON 的 error 归因:额度→改派;超时→放宽或改派;空回复→重试一次
- **`--continue` 仅限串行单任务**:并行/交错派发时会接错会话;多任务续会话用显式会话 ID

### 3.4 adjudicate(裁决)
- 评审发现**逐条复现验证**,以复现结果裁决,不投票;不可复现的不采纳但记录
- 写 `$WORK/verdicts/VERDICT-<id>.md`:每条发现 → 采纳/驳回 + 依据
- **裁决「采纳且必须修」的 P0 = merge 前阻断**:先生成修复卡走小循环,修复并复审通过前禁止 merge——防"评审红灯仍合并,终验再炸"
- 误报也是数据:记入 ledger

### 3.5 merge(合并交付)
- Claude 亲手合并、解决冲突;**合并后必须跑测试/门禁**——机器验证是最后一道质量门,不许跳
- 诚实计数写入 `$WORK/ledger.json`:各家产出数/发现数/误报数,交付时如实汇报,不美化

### 3.6 acceptance(终验对账——done 的唯一放行门)

merge 完成 ≠ 任务完成。拿着 plan 阶段冻结的 `$WORK/REQUIREMENTS.md` **逐条对账**,结论写 `$WORK/ACCEPTANCE-<轮次>.md`(格式见 protocol.md §7b):

1. **逐条判定**:每条需求 → 完成/未完成/存疑
   - 证据必须对应条目冻结时的 **oracle(验证命令+期望结果)**:跑命令、比对输出;无关 diff、永远成功的测试、"看起来做了"一律不算,**证据不足记未完成**(治「两个集合没人对账」)
   - **状态不留灰区**:`部分` 按未完成处理;`存疑` 复核 PASS→完成、FAIL→未完成、复核失败/无人可派→按未完成回炉并记录(复核不钉住 acceptance)
2. **复核双通道(防主持者自查盲区)**:
   - 存疑条目:派跨源 agent 独立复核——它拿需求+oracle **自己跑**,回 PASS/FAIL+理由
   - **抽查通道**:每轮至少抽 1 条「完成」条目做跨源复核,**用户核心诉求条目必复核**——防主持者把假完成标成完成直接放行
3. **回归验证(防改 A 坏 B)**:每轮回炉后,已达标条目的 oracle 重跑(全量成本高时至少抽核心条目)
4. **评审完整性门**:「P0/P1 清零」= 存在评审报告 且 其中 P0/P1 均被裁决关闭;**零评审报告不满足放行**
5. **回炉推动闭环**:未达标条目 → 生成 TASK-F<N> 回炉卡(注明轮次与上轮未达标原因)→ 重走 execute→review→adjudicate→merge→acceptance **完整小循环**;回炉产出的评审尽量换源,防盲区固化
   - **每条需求独立计 3 轮上限**(首轮 acceptance 触发计第 1 轮),轮次记入 state.json;到顶,停下
6. **放行或如实上报例外**:
   - 全部条目「完成+证据+完整性门通过」→ done
   - 确有无法完成的(外部依赖缺失/需求自身矛盾)→ `done-with-exceptions`:向用户输出例外清单(需求/差在哪/卡了几轮/建议),由用户裁决——**不无限硬磨,更不装作完成**
7. **用户裁决后再入 / 需求变更**:
   - 接受例外 = close;继续修 = 例外条目转正式需求,轮次重置(用户重开是新授权)
   - 用户中途改需求 → REQUIREMENTS 换新版本重冻,已交付部分对旧版本对账
8. **单源声明**:仅同源 agent 可用时评审照派,但 ACCEPTANCE 必须声明「本任务为单源评审,置信度降低」

merge 每轮回炉后重复本节,直到放行。

## 4. 交付纪律

- 协作中间产物(任务卡/回包/评审/裁决)只留 `$WORK`,**不进 git、不污染目标仓库**
- 派活 prompt 出 Claude 上下文前脱敏:不含密钥、token、内部 URL
- 汇报格式:分工表 + 各家贡献计数 + 遗留问题;某家被摘除要说明原因(如 codex 额度耗尽)
- 协作不改变责任归属:**交付质量和最终 diff 由 Claude 负责**

## 5. 故障与边界

处置手册见 `references/bad-cases.md`(A 可用性/B 脚本判定/C 执行一致性/D 评审质量/E 交付安全/F 降级/G 终验对账)。核心降级链:摘除→重试1次→改派→Claude 接手;评审无人可派→Claude 自审并向用户声明单源;终验 3 轮不达标→done-with-exceptions 交用户裁决。

## 6. 作者本机实测环境(2026-09-29;你的路径/后端可能不同,按需替换)

- grok v1.0.41(`~/.grok/bin/grok`;必须 `-p`,位置参数会进 TUI 挂死)
- opencode v1.18.33(`~/.opencode/bin/opencode`,glm provider,同 GLM 后端——与 Claude 互审价值低)
- codex(`/opt/homebrew/bin/codex`,2026-09-29 额度恢复后成功路径已实测;非 git 目录需 `--skip-git-repo-check`)
- grok 评审深度高但慢(107s/轮),opencode 快但经 glm 网关有延迟波动(探针预算给 120s+);调度时按此特性路由
