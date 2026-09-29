# acowork · 多 CLI Agent 协作议会

> Claude 是主持者,codex / grok / opencode 是同僚:一起讨论规划、并行干活、交叉质询、裁决交付。
> 一个 Claude Code skill,让本机的多个 AI CLI agent 像一个真正的团队那样协作。

## 为什么需要它

单打独斗的 agent 有两类典型失败:**速度**(串行干活,一个人扛所有任务)和**质量**(同一模型自审=共用盲区,检查者和被检查者错一样)。

acowork 的解法:

| 问题 | 机制 |
|---|---|
| 某 agent 没额度/挂了 | `probe.sh` 探测摘除,一个不派,自动降级;**busy≠死亡**(正被并发派发判「可用,占用中」,不误摘) |
| 多 agent 互相不理解 | `protocol.md` 中立契约自动注入,任何模型读契约即参与 |
| CLI 姿势各异(参数/超时/输出流) | `dispatch.sh` 统一派活器,一套接口全封装 |
| 并行写码互相踩 | 任务卡文件边界不重叠 + 越界作废;**同 agent 并发派发互斥**(agent 锁) |
| 同源模型互审=假绿 | 跨源配对评审(如 codex[xAI/OpenAI] 审 GLM 产出);单源发现标 unconfirmed 不作 P0 阻断 |
| 评审幻觉/误报 | 裁决制:主持者逐条机器复现,不可复现不采纳 |
| 理解漂移 / 计划书冒充执行 | 回声确认:接单先复述理解+边界,不符即停;**内容门禁**:纯「I'll do X」计划书判失败并自动重试 |
| 会话中断全丢 | 文件系统即消息总线:任务卡/回包/评审/裁决全落盘,断点可恢复(`work.sh` 注册表,多会话不串台) |
| **prose 纪律没人执行** | **`gate.sh` 机器放行门**:状态机停滞/幽灵评审文件/账本不守恒/判据无 oracle/无终验对账,八类违规逐项报红带 Fix,不绿不许宣布完成 |
| **做完≠达标** | plan 冻结需求清单(带 oracle+SHA-256 公证)→ acceptance 终验逐条对账:证据不足=未完成、存疑派跨源复核、未达标回炉循环(3 轮上限)、确实做不到→例外清单交用户裁决,不装作完成 |

## 安装

```bash
git clone https://github.com/songyang753-cloud/acowork.git ~/.claude/skills/acowork
# 或任意位置 clone 后软链:
ln -s /path/to/acowork ~/.claude/skills/acowork
```

前置:本机装有 [Claude Code](https://claude.com/claude-code) 和至少一个受支持的 CLI agent(grok / codex / opencode,装哪个协作哪个;一个都没有时 skill 会如实告知并退出,不硬演协作)。脚本依赖 `zsh` 与 `perl`(macOS 自带);CLI 路径可用环境变量 `GROK_BIN / OPENCODE_BIN / CODEX_BIN` 覆盖(换机器不用改脚本,也是测试注入点)。

改动脚本后跑行为测试:`zsh scripts/test.sh`(假 CLI + 隔离状态目录,覆盖额度/超时/空回复/词边界/内容门禁/锁/state 推进/gate 违规等判定分支,41 用例全绿才算过;测试不碰真实 `~/.local/state/acowork`)。

## 使用

对 Claude 说:

```
叫上 grok 和 opencode 一起把这个功能做了,写完互相 review
让大家协同规划这个任务的分工
让 codex 和 grok 交叉审查这段代码
```

Claude 会按任务形态走两条正式路径之一:

```
full(写码交付):
probe(探测可用)→ plan(冻结需求+oracle)→ [confirm(一轮意见)]
→ execute(并行执行)→ review(跨源交叉评审)→ adjudicate(裁决+复现)→ merge(合并+跑测试)
→ acceptance(终验对账:逐条对需求,未达标回炉,3轮上限)→ done / done-with-exceptions

review-only(纯评审/核实/数据审查):
probe → plan → dispatch → 逐条复现裁决 → ledger+gate → 汇报(发现处置对账:raw=采纳+驳回+待办)
```

两条路径都过 `gate.sh`;每轮汇报固定含「本轮派发: grok✓ codex✓ opencode✗(原因)」——**跳过谁必须点名,禁止静默 solo**。

## 仓库结构

```
acowork/
├── SKILL.md               # 主持者手册(Claude 视角:三条硬规则+两条路径+调度原则)
├── protocol.md            # 中立协作契约(角色/任务卡/回包/评审/裁决格式+状态机+账本单位)
├── references/bad-cases.md  # 69 条 bad case 处置手册(A可用性/B脚本判定/C一致性/D评审/E安全/F降级/G终验对账)
└── scripts/
    ├── probe.sh           # 可用性探测 → JSON roster(额度摘除;busy≠死亡)
    ├── dispatch.sh        # 统一派活器(姿势封装 + --readonly 只读锁 + 进程组超时 + 内容门禁
    │                      #   + --out 成功才落盘 + agent 锁 + 空回复自动重试 + state.json 自动推进)
    ├── work.sh            # 工作区注册表(add/close/list;多会话不串台,断点恢复入口)
    ├── gate.sh            # 机器放行门(八类违规逐项报红带 Fix;--final 不绿不许宣布完成)
    └── test.sh            # 行为测试(假 CLI+隔离状态目录,41 用例,失效清单驱动)
```

**物理只读锁**是评审环节的关键:grok 用工具白名单、codex 用 read-only 沙箱、opencode 用 plan agent——评审者想改也改不了,不靠自觉。**机器门禁是交付环节的关键**:纪律写在文档里没人执行,写进脚本里才 100% 执行——skill 层的 gate.sh 管「不绿不许汇报」,脚本层的 dispatch 副作用管「状态自动记账、失败自动删文件、计划书自动拦」。

## 实测记录(2026-09-29,建仓当日)

不是纸面设计,每个环节都真跑过:

- **probe 摘除**:codex 配额耗尽被正确摘除(天然反例验证);额度恢复后探针即放行,成功路径(80s 评审)同日补验
- **交叉评审抓真 bug**:建设过程中 grok 反向揪出本仓脚本 14 条真问题(关键词误杀成功回包、`429` 无词边界、stderr 丢失归因、perl `exec` 静默 exit 0、prompt 回显假阳性……),全部修复复测
- **全流程 demo**:opencode 写 `slugify.ts`(回声确认生效)→ grok 跨源评审出 4 条边界发现(P1:中文标题产生空 slug)→ 主持者 node 复现 4/4 命中 → 裁决书+诚实计数账本落盘
- **双源评审差异样本**:同一份代码,grok 判「中文空 slug」为 P1(推动规格演进),codex 判「符合声明的 ASCII 白名单」零发现(验收字面实现)——两家都对,视角互补,裁决权在主持者
- **网络抖动处置**:opencode 经 glm 网关延迟波动,90s 探针超时摘除 → 按手册重探一次 → 58s 恢复;probe 默认超时已放宽至 120s
- 全部判定教训沉淀进 `references/bad-cases.md`,标 🌱 的都是实测踩过的

## v1.4:同日四轮真实使用暴露 12 问题 → 全修(2026-09-29)

skill 建成当天即在两个会话里真实跑了四轮(AIOS 意图分发测试集 review×3、SYBuilder 修复核验×1),暴露 12 个问题,**根因同一个:规则全在 prose 里,零机器门禁——「workflow 携带行为,SKILL.md 文本不携带」**(此结论经 20 个同类高分仓调研交叉验证,superpowers/trailofbits/claudex-loop/agent-harness 给出同一答案:把权威从 LLM 手里拿走)。v1.4 的三层机器权威:

- **dispatch.sh 副作用层**:state.json 随派发自动推进(治「状态机永远停在 probe」);`--out` 成功才落盘(治幽灵评审文件);内容门禁拦计划书 stub;空回复自动重试;agent 锁并发互斥;stdout 文件捕获治超时失控(受控实验:孙进程持管道 20s→0s)
- **gate.sh 放行门**:八类违规(幽灵文件/无实质内容/状态停滞/判据无 oracle/账本不守恒/无终验对账/残留文件/未注册)逐项报红带 Fix;**回归验收=对当天四个真实工作区跑 gate,已知缺陷全部精确报红才算门禁成立**
- **work.sh 注册表**:一轮一行替代全局指针,多会话并发不串台;busy≠死亡,probe 不再误摘正在干活的 agent

配套:SKILL.md 从 300 行瘦身到 112 行(三条硬规则+两条正式路径+数据出境三档),protocol.md 定死账本单位,新增 7 条实测 bad case,测试从 14 用例扩到 41(每个用例名=一个真实失效形态)。

## 已知边界(如实)

- 各 CLI 的额度/网络是外部依赖:探测只代表探测时刻,任务中失败走降级链(重试1次→改派→主持者接手)
- 协作有 token 成本:单家产出 <200 字的活不值得派,自己做
- 涉密内容不要派给外部 agent(prompt 会离开主持者上下文)

## 镜像

本仓(GitHub)是主仓,内容与内网 GitLab `songyang/acowork` 保持同步(手动双推);两处内容应一致,发现漂移以 GitHub 为准。

## License

MIT
