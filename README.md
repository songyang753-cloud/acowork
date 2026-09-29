# council · 多 CLI Agent 协作议会

> Claude 是主持者,codex / grok / opencode 是议员:一起讨论规划、并行干活、交叉质询、裁决交付。
> 一个 Claude Code skill,让本机的多个 AI CLI agent 像一个真正的团队那样协作。

## 为什么需要它

单打独斗的 agent 有两类典型失败:**速度**(串行干活,一个人扛所有任务)和**质量**(同一模型自审=共用盲区,检查者和被检查者错一样)。

council 的解法:

| 问题 | 机制 |
|---|---|
| 某 agent 没额度/挂了 | `probe.sh` 探测摘除,一个不派,自动降级 |
| 多 agent 互相不理解 | `protocol.md` 中立契约自动注入,任何模型读契约即参与 |
| CLI 姿势各异(参数/超时/输出流) | `dispatch.sh` 统一派活器,一套接口全封装 |
| 并行写码互相踩 | 任务卡文件边界不重叠 + 越界作废 |
| 同源模型互审=假绿 | 跨源配对评审(如 codex[xAI/OpenAI] 审 GLM 产出) |
| 评审幻觉/误报 | 裁决制:主持者逐条机器复现,不可复现不采纳 |
| 理解漂移 | 回声确认:接单先复述理解+边界,不符即停 |
| 会话中断全丢 | 文件系统即消息总线:任务卡/回包/评审/裁决全落盘,断点可恢复 |

## 安装

```bash
git clone https://github.com/songyang753-cloud/council.git ~/.claude/skills/council
# 或任意位置 clone 后软链:
ln -s /path/to/council ~/.claude/skills/council
```

前置:本机装有 [Claude Code](https://claude.com/claude-code) 和至少一个受支持的 CLI agent(grok / codex / opencode,装哪个协作哪个;一个都没有时 skill 会如实告知并退出,不硬演协作)。

## 使用

对 Claude 说:

```
叫上 grok 和 opencode 一起把这个功能做了,写完互相 review
让大家协同规划这个任务的分工
让 codex 和 grok 交叉审查这段代码
```

Claude 会自动走完整流程:

```
probe(探测可用)→ plan(规划分工)→ [confirm(一轮意见)] 
→ execute(并行执行)→ review(跨源交叉评审)→ adjudicate(裁决+复现)→ merge(合并+跑测试)
```

## 仓库结构

```
council/
├── SKILL.md               # 主持者手册(Claude 视角:调度原则+交付纪律)
├── protocol.md            # 中立协作契约(角色/任务卡/回包/评审/裁决格式+状态机)
├── references/bad-cases.md  # 33 条 bad case 处置手册(A可用性/B脚本判定/C一致性/D评审/E安全/F降级)
└── scripts/
    ├── probe.sh           # 可用性探测 → JSON roster(没额度直接摘除)
    └── dispatch.sh        # 统一派活器(姿势封装 + --readonly 物理只读锁 + 超时 + 标准回包)
```

**物理只读锁**是评审环节的关键:grok 用工具白名单、codex 用 read-only 沙箱、opencode 用 plan agent——评审者想改也改不了,不靠自觉。

## 实测记录(2026-09-29,建仓当日)

不是纸面设计,每个环节都真跑过:

- **probe 摘除**:codex 配额耗尽被正确摘除(天然反例验证);额度恢复后探针即放行,成功路径(80s 评审)同日补验
- **交叉评审抓真 bug**:建设过程中 grok 反向揪出本仓脚本 14 条真问题(关键词误杀成功回包、`429` 无词边界、stderr 丢失归因、perl `exec` 静默 exit 0、prompt 回显假阳性……),全部修复复测
- **全流程 demo**:opencode 写 `slugify.ts`(回声确认生效)→ grok 跨源评审出 4 条边界发现(P1:中文标题产生空 slug)→ 主持者 node 复现 4/4 命中 → 裁决书+诚实计数账本落盘
- **双源评审差异样本**:同一份代码,grok 判「中文空 slug」为 P1(推动规格演进),codex 判「符合声明的 ASCII 白名单」零发现(验收字面实现)——两家都对,视角互补,裁决权在主持者
- **网络抖动处置**:opencode 经 glm 网关延迟波动,90s 探针超时摘除 → 按手册重探一次 → 58s 恢复;probe 默认超时已放宽至 120s
- 全部判定教训沉淀进 `references/bad-cases.md`,标 🌱 的都是实测踩过的

## 已知边界(如实)

- 各 CLI 的额度/网络是外部依赖:探测只代表探测时刻,任务中失败走降级链(重试1次→改派→主持者接手)
- 协作有 token 成本:单家产出 <200 字的活不值得派,自己做
- 涉密内容不要派给外部 agent(prompt 会离开主持者上下文)

## License

MIT
