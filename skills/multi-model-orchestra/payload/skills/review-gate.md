---
name: review-gate
description: 合并请求（PR/MR）推送或上线前必须使用——对已提交的改动跑 Codex 审查，两级分类（阻断/建议）、最多两轮、超限交用户决定。用户说「提 PR / 合并 / 推送 / 上线 / 过审查」时，或 git push 被审查门拦住时使用。
---

# 合并前审查门：两级、最多两轮、超限交用户

**为什么**：Claude 和 Gemini 必然会漏东西，最后一道关交给 GPT。但 GPT 审查太极端——曾把同一个合并请求连退三轮（12、10、8 条），后两轮几乎全是第一轮的延伸、要好几件事凑巧同时发生才会出现。所以：**只拦会出事故的，其余只记录；最多两轮。**

## 流程
1. 先提交（审查绑定**已提交的内容**；工作区不干净会被拒）。
2. 跑一轮（耗时，放后台）：
   ```bash
   bash .orchestra/bin/codex-review run --intent "<这次改动要做什么，一两句>"
   ```
   脚本自动：选基线分支 → 命中敏感路径用 xhigh、否则 high → 把改动与意图交给 Codex（只读沙箱）→ 按两级规则判定 → 记账。
3. 看退出码：
   | 码 | 含义 | 你做什么 |
   |---|---|---|
   | 0 | 通过（已记录） | 可以推送，git pre-push 门会放行 |
   | 1 | 有阻断项，还有轮次 | **只修阻断项**，提交，再 `run`（第 2 轮会带上上一轮阻断项让审查者复核）。建议项不返工 |
   | 2 | 审满轮数仍有阻断项 | **停。交给用户决定**（见下） |
   | 3 | 结论无效（自相矛盾/不是 JSON） | 不计轮次，直接重跑 |
   | 4 | 前置条件不满足（工作区脏、找不到基线、内容没变就重审） | 按提示处理 |
   | 5 | 审查者不可用 | 明说，**别悄悄换别的模型**；让用户决定 |
4. 脚本会把「说不出怎么发生」的阻断项自动降为建议，也不会让「上一轮没被明确说已修好」的阻断项溜走。
5. **收到结论先分诊，再动手**（总指挥的活，别照单全收）：这条是严重类吗？说得出怎么发生吗？要不要多件事凑巧？在威胁模型内吗？任一条否 → 记成建议或已知限制，一行，不修。`--intent` 里写一句威胁模型（对手是谁：诚实的失误？恶意提交者？）；每轮的修复要比上一轮小，审查条数不降反升就是范围在膨胀——停，交用户。见 `rules.md` §8。

## 升级给用户（退出码 2）
向用户提问，把每个阻断项的**位置＋怎么发生**摆出来（人话，别贴原始 JSON），选项：**放行上线 / 再审一轮 / 我先看看**。用户答复**之后**才能执行，`--by` 里写用户原话：
```bash
bash .orchestra/bin/codex-review approve --by "<用户原话>"     # 放行（只对这一份内容有效，之后再改又要审）
bash .orchestra/bin/codex-review again   --by "<用户原话>"     # 多给一轮额度；修完再 run
```
**不得自行放行**；不得 `git push --no-verify`、不得 `ORCH_GATE=off`（钩子会拦；这些只有用户本人能用）。需要外部通知时：`export ORCH_NOTIFY_CMD='bash .orchestra/bin/notify-feishu'` 并设好 `ORCH_FEISHU_WEBHOOK`（飞书自定义机器人）。

## 让 CI 也能核验
审查通过（或用户放行）时会自动写一份**审查凭证**（git notes，挂在树上，不带时间戳、身份中性；放行的只带审计引用 `by_ref`，**不带用户原话**）。通过后：
```bash
bash .orchestra/bin/codex-review publish                                 # 把凭证推到 origin（本机有通过记录而凭证缺了，会先补上）
# CI 里（脚本必须取自目标分支的可信副本，不能直接跑 PR 里的那份——PR 能把它改成永远放行）：
ORCH_BASE=origin/<目标分支> bash <可信副本>/.orchestra/bin/review-gate-check --ci <PR头提交>
# 退出码：0 有凭证（或相对基线没有改动）｜1 拦住（没凭证 / 取不到远端凭证 / ORCH_BASE 不是远端跟踪分支）｜4 环境不满足（浅克隆）
```
内容在审查之后又改过，凭证就不算数（要重审再 publish）。要让它真的拦住合并，得在托管平台上把这个 CI 任务设为必需的状态检查。怎么接（可信副本、基线规矩、局限）详见 `docs/CI接入.md`。

## 配置
- 敏感路径（钱 / 权限登录 / 对外发消息 / 往外部系统写数据）：把 `.orchestra/sensitive-paths.example` 复制为 `.orchestra/sensitive-paths` 再按你的仓库改（非 ASCII 路径也能命中）。
- 档位、轮数、降级阈值：`.orchestra/orchestra.conf`。
- **基线分支**：`--base` > `ORCH_BASE` > `git config orchestra.base` > `origin/HEAD`（这几项有明确依据）> origin 或本地的 main/master/trunk/develop（这是猜的）。配置里写裸分支名（`main`）而 origin 有它的远端副本时，**用 `origin/main`**（本地 main 可能带着没推的未审提交，拿它当基线就成了自己跟自己比；想强制用本地分支写 `refs/heads/main`）。**认不出基线时门会拦住**（fail-closed）并告诉你怎么配；**基线是猜的、而被推送的提交相对它没有任何改动时**也拦住——那个「没有改动」不可信（比如默认分支其实叫 release，本地 develop 被猜成基线）。`install.sh --git-hook` 在能确定时顺手把基线配成显式的。
- 想让「没过审查就推不上去」：`bash install.sh --git-hook <仓库根目录>`（必须是 git 仓库根；子目录/非 git 目录会失败）。它在 `.git/hooks/pre-push` 装一个**转发桩**（第 2 行是 `# orchestra-stub:`），真正的门逻辑在仓库里的 `.orchestra/githooks/pre-push`，随套件更新、不用再动 `.git/hooks`。linked worktree 里没有套件（比如从装套件之前的提交建的）时，桩会回退到**主工作区**的套件；**哪里都找不到门脚本就拦住**，不会静默放行。**已有的、不是我们的 pre-push（含 husky 的 `core.hooksPath`）绝不覆盖**，只告诉你怎么接——接法：把下面两行放在你的 pre-push**最前面**（它要读标准输入；你自己的逻辑如需读 ref 输入，改读 `$refs`）：
  ```sh
  refs=$(cat)
  printf '%s\n' "$refs" | bash .orchestra/githooks/pre-push "$@" || exit 1
  ```
  钩子按**目标 ref** 判断，所以 `git push origin <提交号>:refs/heads/x`、`HEAD:refs/heads/x` 一样会被拦；推 tag、删分支不用审。CI 里要用的是 `review-gate-check --ci`（读审查凭证，见上面「让 CI 也能核验」）——不带 `--ci` 的那种读的是本机的 `.git/orchestra/`，CI 里没有。

## T3 路径（没有 shell 调 Codex 时）
```bash
bash .orchestra/bin/codex-review prompt --intent "…"     # 打印本轮完整审查提示词；stderr 里有该用的模型和推理档
```
`delegate_task({ role:"review", isolation:"worktree", mode:"async", target:{ providerInstanceId:"codex", model:"<CODEX_REVIEW_MODEL>", options:{ reasoningEffort:"<high 或 xhigh>" } }, task:"<提示词＋「只输出符合 schema 的 JSON」>" })`；
子任务交回的 JSON 存成文件，再 `bash .orchestra/bin/codex-review record <文件> --request <请求ID>`——同一套判定和记账。请求ID 在 `prompt` 的 stderr 里（`# 请求ID: rq-…`）。
- `prompt` 会记下「审的是哪份内容」并发一个请求ID，`record` 只认这份、必须带同一个 `--request`：期间你又提交了新内容，或者又跑了一次 `prompt`，旧结论的 `record` 都会被拒绝（退出码 4）——迟到的旧结论不能记到新内容头上，重新 `prompt` 即可。没跑过 `prompt` 直接 `record` 同样被拒。
- `prompt` / `record` 与 `run` 共用轮次上限和「同内容不重审」：审满轮数后不再出提示词、不再记账，直接升级（退出码 2）。
- 结论必须**完整符合 schema**（`verdict`、`summary`、`previous_blockers`、`blocking`、`advisory` 五个字段齐全、类型对），缺字段或类型不对一律判无效（退出码 3，不计轮次）。
- **每一轮复审都新开一个 delegate_task**，别在原线程里追问（要的是不带先入之见的新眼睛）。
