---
name: multi-model-orchestra
description: 把「Claude 总指挥＋Gemini 军师＋Codex 工兵/守门人」的多模型编排套件装进当前项目（常驻规则、5 个子 Skill、守卫钩子、合并前审查门），并说明装好后怎么用。用户新建项目想按这套流程做、说「接入编排」「按编排流程来」「多模型协同」，或要更新已装的套件时使用。项目里已有 .orchestra/ 时规则已常驻，平时不用调用本技能。
---

# 多模型编排套件：装进项目，之后用户只管说需求和拍板

**这是什么**：Claude 当总指挥（听懂需求、拆解、验收、汇报），Gemini 当军师（独立第二方案、文案与交互顾问，只读），Codex 当工兵和守门人（成块的后端/算法/数据/性能、浏览器操控、合并前审查）。本技能自带整套脚本、规则和 5 个子 Skill，一条命令装进项目；装完规则、钩子、审查门都在项目里自动生效，之后不依赖本技能。

## 先判断要不要装
- **装**：新项目/新仓库想按这套流程做；用户说「接入编排」「按编排流程来」；要把已装的套件升到新版。
- **不装**：项目根目录已有 `.orchestra/`——规则已经常驻（`CLAUDE.md` 引入了 `.orchestra/rules.md`），照规则干活即可。用户只是问「怎么用」，用下面「装好后怎么用」回答。

## 装进当前项目
> `${CLAUDE_SKILL_DIR}` 是本技能所在的目录；如果它没被替换成路径，就用加载本技能时系统给出的 Base directory。需要 bash、git、node。

1. **确认当前目录是 git 仓库根**（`git rev-parse --show-toplevel`）。不是 git 仓库 → 问用户要不要在这里 `git init -b main`（同意了再做；审查门和 worktree 派活都需要 git）。
2. **先预演**（什么都不写），用一句话告诉用户会装什么：
   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/adopt.sh" --dry-run --git-hook .
   ```
3. **用户同意后正式装**：
   ```bash
   bash "${CLAUDE_SKILL_DIR}/scripts/adopt.sh" --git-hook .
   ```
   `--git-hook` 会装 git pre-push 审查门（没过审查的分支推不上去）并把基线分支配好；用户不要这道硬门就去掉它。已有的 `CLAUDE.md`、`.claude/settings.json` 只追加/合并；用户改过的配置、提示词、规则不会被覆盖（套件新版另存为 `.kit-new`）。
4. **装完告诉用户三件事**：
   - 要提交 `.orchestra/ .claude/ CLAUDE.md .gitignore .gitattributes`（用户说提交再提交，别自己提交）；
   - **必须在这个目录新开一个会话**，规则和 Skill 才会载入（当前会话读的还是装之前的）；
   - 体检：`bash .orchestra/bin/codex-worker --doctor`。碰钱、权限登录、对外发消息、写外部系统的文件，可选把 `.orchestra/sensitive-paths.example` 复制成 `.orchestra/sensitive-paths` 再改（命中的文件审查用更深的推理档）。

## 装好后怎么用（用户不用记命令）
| 用户说 | 发生什么 | 子 Skill |
|---|---|---|
| 一个大方案 / 架构取舍 | 总指挥出一份 ＋ Gemini 独立一份 → 逐条核实、合并 → 用户拍板 | `dual-plan` |
| 做/改一个界面 | 自己做 → Gemini 顾问改文案与交互 → 对照功能核实后采纳 | `copy-advisor` |
| 成块的后端/算法/数据处理/性能；网页操控 | 写任务书 → Codex 在独立 worktree 干 → 读 diff、自己复跑测试 | `codex-delegate` |
| 提 PR / 推送 / 上线 | Codex 审查：只拦会出事故的、最多两轮、超限问用户 | `review-gate` |
| 用户纠正了一次 | 同一个 PR 里把这一类写成检查或结构，旧违规记欠账只许减少 | `error-to-check` |

几十行的小改动、改几个字，总指挥自己做，不派活。

**哪些是自动的**：守卫钩子和 git 审查门是硬拦（自动生效，只有用户本人 `--no-verify` 能绕）；规则和子 Skill 是软的——靠总指挥按规则判断，没触发时用户可以点名（「走双方案」「派给 Codex」「过审查」）。

## 更新套件
重跑第 3 步的命令即可（幂等）。用户改过的文件不覆盖，套件新版另存为 `.kit-new`，自己 diff 后取舍。

## 限制（实话）
- Gemini：在 T3 Code 里走 `delegate_task`（Antigravity 提供方），其他环境用命令行 `agy`（`agy-ask`）；命令行 `agy` 可能被服务端的账号/地区校验拒绝，此时一律走 T3。换模型只改 `.orchestra/orchestra.conf`。
- 审查凭证、CI 核验、飞书通知只在本地和假服务上验证过，没在真实平台跑过。详见 `docs/调度结构.md` §8 和 `docs/CI接入.md`。
- 外发边界：Gemini/Codex 会读到你给它的目录和工作树，涉密仓库先问用户。

## 更多
`docs/调度结构.md`（结构、角色、关键数字、已知限制）· `docs/CI接入.md`（审查凭证在 CI 里怎么核验）。
