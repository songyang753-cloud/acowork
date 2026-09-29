---
name: council
description: 本机多 CLI agent 协同工作(Claude 主持,codex/grok/opencode 为同僚)。当用户要「多agent协作/协同工作/大家一起干/一起规划分工/交叉审查/互相review/叫上 codex/grok/opencode/发挥各家优势/团队协作提升交付速度和质量」时使用。核心机制:协议中立化(protocol.md 注入,任何 agent 都能按契约参与)、文件系统即消息总线(共享工作区+状态机,断点可恢复)、探测摘除(没额度的不派活)、跨源交叉评审(避开同源模型盲区)、统一派活器封装全部 CLI 姿势差异、回声确认防理解漂移、裁决制+机器门禁保质量。
---

# council:多 CLI Agent 协同(Claude 主持)

> council = 议会:Claude 是主持者,codex/grok/opencode 是议员;讨论、分工、质询、裁决。

四个 agent(Claude/codex/grok/opencode)协同交付:讨论规划 → 并行执行 → 交叉评审 → 裁决合并。**Claude 是主持者和最终责任人,不是发号施令的旁观者**——每一步的质量门都由 Claude 亲手把。

## 0. 何时用 / 不用

**用**:中型以上任务要提速(并行执行+流水线评审);单一视角不放心,要跨模型交叉审查;要对抗「检查者共用假设⇒假绿」。
**不用**:琐碎小改(编排开销>收益);涉密内容不许出本机会话(派活 prompt 会出 Claude 上下文);用户赶时间且只要快不要多方视角。

**成本自觉**:每次派活都是真实 token。审批规则:预计单家产出 <200 字的活不派,自己做。

## 1. 一次性准备(每个协作任务开头)

```bash
SKILL=<本skill目录>   # 如 ~/council(clone 到哪就是哪)
WORK=$(mktemp -d /tmp/council.XXXXXX) && mkdir -p $WORK/{tasks,replies,reviews,verdicts}
zsh $SKILL/scripts/probe.sh 90 > $WORK/roster.json        # 可用性探测,stdout=JSON
```

- roster 里 `available:false` 的 agent,**写码和评审都不派**(用户明确要求)
- 同一任务内复用 roster;跨任务必须重探(额度会变)
- 全员不可用 → 告知用户,Claude 独立完成,不硬演协作

## 2. 状态机与推进(Claude 的主持循环)

```
probe → plan → [confirm] → execute → review → adjudicate → merge → done
```

每步把进度写进 `$WORK/state.json`(`{"phase":"...","tasks":[...]}`);会话断了从它恢复,文件全在 `$WORK`,别依赖对话记忆。

## 3. 各步操作

### 3.1 plan(规划与分工)
- Claude 起草:任务拆分(标注依赖,DAG)、每张任务卡五要素(见 protocol.md §4)、验收标准优先写成可机器验证的
- **文件边界不重叠**是并行写码的前提;有重叠的排串行
- 调度六原则(protocol.md §8):可用性优先 / 跨源配对 / 独立并行 / 流水线(完成即审不等全员)/ 负载均衡 / 特长路由(grok=500k 长上下文+联网,opencode=GLM 快糙,claude=裁决合并)

### 3.2 confirm(中大任务才做;小任务跳过)
把规划摘要派给每个可用 agent 征一轮意见,任务卡就一句话:「对分工/边界/验收有异议吗?≤100 字,无异议回 LGTM」。**只此一轮**,有价值的意见吸收后由 Claude 裁决定稿,不开自由讨论。

### 3.3 execute + review(统一用 dispatch.sh,永不手拼 CLI 命令)

```bash
# 执行(写码):--cwd 指向目标仓库
zsh $SKILL/scripts/dispatch.sh <agent> $WORK/tasks/TASK-1.md --cwd <目标仓库> \
  > $WORK/replies/REPLY-1.md 2>>$WORK/dispatch.log

# 评审:--readonly 物理只读锁(grok=工具白名单/codex=read-only沙箱/opencode=plan agent)
zsh $SKILL/scripts/dispatch.sh <agent> $WORK/tasks/TASK-R1.md --readonly --timeout 300 \
  > $WORK/reviews/REVIEW-1-by-<agent>.md 2>>$WORK/dispatch.log
```

- dispatch 自动注入 protocol.md 前缀,对方自动知道契约(这就是「大家一起用」:协议在文件里,不在谁的脑子里)
- 多家并行:Bash 并行调用;评审**流水线式**,一家完成即派审
- 评审超时预算 300s(grok 深审实测 107s+)
- dispatch 失败(exit 1)看 stderr JSON 的 error 归因:额度→改派;超时→放宽或改派;空回复→重试一次

### 3.4 adjudicate(裁决)
- 评审发现**逐条复现验证**,以复现结果裁决,不投票;不可复现的不采纳但记录
- 写 `$WORK/verdicts/VERDICT-<id>.md`:每条发现 → 采纳/驳回 + 依据
- 误报也是数据:记入 ledger

### 3.5 merge(合并交付)
- Claude 亲手合并、解决冲突;**合并后必须跑测试/门禁**——机器验证是最后一道质量门,不许跳
- 诚实计数写入 `$WORK/ledger.json`:各家产出数/发现数/误报数,交付时如实汇报,不美化

## 4. 交付纪律

- 协作中间产物(任务卡/回包/评审/裁决)只留 `$WORK`,**不进 git、不污染目标仓库**
- 派活 prompt 出 Claude 上下文前脱敏:不含密钥、token、内部 URL
- 汇报格式:分工表 + 各家贡献计数 + 遗留问题;某家被摘除要说明原因(如 codex 额度耗尽)
- 协作不改变责任归属:**交付质量和最终 diff 由 Claude 负责**

## 5. 故障与边界

处置手册见 `references/bad-cases.md`(A 可用性/B 脚本判定/C 执行一致性/D 评审质量/E 交付安全/F 降级路径)。核心降级链:摘除→重试1次→改派→Claude 接手;评审无人可派→Claude 自审并向用户声明单源。

## 6. 本机环境事实(2026-09-29 实测)

- grok v1.0.41(`~/.grok/bin/grok`,sub2api 转光帆网关;必须 `-p`,位置参数会进 TUI 挂死)
- opencode v1.18.33(`~/.opencode/bin/opencode`,glm provider,同 GLM 后端——与 Claude 互审价值低)
- codex(`/opt/homebrew/bin/codex`,额度曾耗尽至 10-04;非 git 目录需 `--skip-git-repo-check`)
- grok 评审深度高但慢(107s/轮),opencode 快;调度时按此特性路由
