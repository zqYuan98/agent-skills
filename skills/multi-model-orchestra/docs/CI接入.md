# CI 接入：让「没审过进不了 CI」在服务端也成立

本机的审查记录在 `.git/orchestra/`，CI 看不见。所以审查通过（或被用户放行）时，会同时写一份**审查凭证**——`git notes`（`refs/notes/orchestra-review`）：

- 挂在**树对象**上，按「树＋基线」匹配：amend、改提交说明、rebase 后内容没变，凭证照样有效；内容变了就失效。
- 一次审查追加一段：`key=<树>-<基点前12位>`、`status=pass|approved`、轮次、模型、推理档；用户放行的还带 `by_ref=<审计引用>`。
- **凭证里没有用户原话。** 它会被推到远端、被 CI 打印，而原话可能带姓名、邮箱、时间。原话和 `by_ref` 对应着留在放行那台机器的 `.git/orchestra/review/audit.log` 里，要核对「谁放行的」，去那里按引用查。
- **不带时间戳**；凭证提交的身份是中性的 `orchestra`、日期固定为 2000-01-01 UTC，也不建 reflog——不能把你的本地时间、时区、姓名邮箱带出去。

## 先读这个：脚本不能取自被核验的内容
CI 核验的是「这个 PR 的内容有没有审查凭证」。**如果 CI 直接跑 PR 里的 `.orchestra/bin/review-gate-check`，PR 把它改成「永远退出 0」就过了**（`.orchestra/lib/`、`orchestra.conf` 同理）——测试里专门复现过这一条。所以：

1. CI 只执行**目标分支（受保护）上的**脚本；PR 的内容只当作「待核验的数据」，里面的任何东西都不执行。
2. 工作流定义本身也要来自受保护的来源，否则 PR 能直接把这个检查任务改掉（GitHub 用 `pull_request_target`，见下；GitLab 见下面的说明）。
3. 给 `.orchestra/**` 和 CI 配置文件设 CODEOWNERS（必须经负责人审批）。

## 流程
1. 本机：`bash .orchestra/bin/codex-review run` 通过（或用户 `approve`）→ 凭证自动写进本地。
2. `bash .orchestra/bin/codex-review publish` → 推到 origin。别人也发布过导致被拒时，自动取回对方的、按 union 合并（两边的段落都保留、重复的去掉）再推。本机的通过记录有而凭证缺了（被误删、当时没写成），`publish` 会先从通过记录补上。
3. 推分支、开 PR/MR。
4. CI 里：用目标分支上的可信副本，对 PR 的头提交跑
   ```bash
   ORCH_BASE=origin/<目标分支> bash <可信副本>/.orchestra/bin/review-gate-check --ci <PR头提交>
   ```
   当前目录是 PR 的检出（脚本读它的 git 数据）；脚本自己是可信副本里的那份。

`--ci` 的规矩（每一条都有测试）：
- **不猜基线**，必须显式设 `ORCH_BASE`，而且必须是**远端跟踪分支**（`origin/main`）。`HEAD`、提交号、本地分支、标签一律拒绝——它们能让「相对基线没有任何改动」变成假的，任何未审内容都会被放过。同名标签（叫 `origin/main` 的标签）也抢不过它；继承来的环境变量 `BASE` 不起作用。
- 基线分支要先取到：`git fetch origin +refs/heads/<目标分支>:refs/remotes/origin/<目标分支>`（`fetch-depth: 0` / `GIT_DEPTH: 0` 的完整检出已经有）。
- 凭证每次现取，取到**本次调用独有的**临时 ref，用完即删：**取不到（远端没有凭证 ref、被回滚、连不上）就失败**，不会拿上次留下的旧副本核验通过；你在本机自测 `--ci` 也不会冲掉还没发布的本地凭证。不写 reflog、不写 `FETCH_HEAD`。
- 推送的提交已经在目标分支的历史里（相对基线没有改动）→ 放行，不需要凭证。

**退出码**：`0` 有凭证（会打印出来）或相对基线没有改动 ｜ `1` 拦住：没凭证、取不到远端凭证、`ORCH_BASE` 没设或不是远端跟踪分支 ｜ `4` 环境不满足：浅克隆算不出合并基点（要完整历史）、找不到提交。任何非 0 都让 CI 任务失败。

## GitHub Actions 示例
> 示例：**没有在真实 CI 上跑过**。脚本本身用「本地 bare 仓库当远端、全新克隆当 CI」验证过（`tests/run.sh`「CI 可核验的审查凭证」「增量审查第 1 轮的回归」两节：篡改门脚本、基线造假、远端凭证消失、并发写、浅克隆等）。
```yaml
name: review-gate
on:
  pull_request_target:            # 工作流文件取自【目标分支】：PR 里改工作流不会生效
    types: [opened, synchronize, reopened]
permissions:
  contents: read
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      # 1) 可信副本：目标分支上的脚本。只执行这一份
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: trusted
          persist-credentials: false
      # 2) 待核验的内容：PR 的头提交。只当数据读，里面的任何东西都不执行
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          path: candidate
          fetch-depth: 0
      - name: 审查凭证核验
        working-directory: candidate
        env:
          ORCH_BASE: origin/${{ github.base_ref }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: bash ../trusted/.orchestra/bin/review-gate-check --ci "$HEAD_SHA"
```
说明：`pull_request_target` 会带上仓库的读权限，所以**绝不能在这个任务里执行 `candidate/` 里的任何东西**（不跑它的脚本、不 `npm install`、不跑它的测试）。

**这一段我没有验证，上线前请你自己试一次：** `pull_request_target` 的运行归在目标分支的提交名下，它的检查结果在 PR 上怎么显示、能不能当「必需的状态检查」真的挡住合并，要在你的仓库里实测。做法：开一个**故意没有审查凭证**的测试 PR，确认这个任务失败、而且合并按钮被挡住；再开一个有凭证的，确认能合。挡不住的话两个办法：用平台的「必需工作流」（GitHub 组织规则集里的 Require workflows，工作流定义来自受保护的仓库）；或让这个任务把结果明确写到 PR 头提交上（commit status API），再把那个状态设为必需。

## GitLab CI 示例（同样没在真实 CI 上跑过）
```yaml
review-gate:
  stage: test
  variables:
    GIT_DEPTH: "0"
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  script:
    - T="$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
    - git fetch origin "+refs/heads/$T:refs/remotes/origin/$T"
    # 可信副本：目标分支上的脚本；MR 分支里的 .orchestra 不执行
    - rm -rf /tmp/orch-trusted && mkdir -p /tmp/orch-trusted
    - git archive "refs/remotes/origin/$T" .orchestra | tar -x -C /tmp/orch-trusted
    - ORCH_BASE="origin/$T" bash /tmp/orch-trusted/.orchestra/bin/review-gate-check --ci "${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-$CI_COMMIT_SHA}"
```
说明：GitLab 的流水线配置（`.gitlab-ci.yml`）就在 MR 分支里，作者能改它。要把「门」放到作者改不了的地方：把这个任务写在受保护的另一个项目里、用 `include: project:` 引入，并给 `.gitlab-ci.yml` 设 CODEOWNERS 必须审批；或用平台的合规流水线 / 流水线执行策略。「合并结果流水线」里 `CI_COMMIT_SHA` 是合成的合并提交，要核验的是源分支的头提交，所以上面优先取 `CI_MERGE_REQUEST_SOURCE_BRANCH_SHA`。这部分我没有验证。

## 要让它真的「进不了」
CI 任务只是个检查。要让它**拦住合并**，得在托管平台上把这个任务设为**必需的状态检查**（GitHub：分支保护 → Require status checks to pass；GitLab：Pipelines must succeed / 受保护分支），并给 `.orchestra/**`、CI 配置设 CODEOWNERS。这几步只能你在平台上做，脚本替不了。

## 局限（写在前面，别指望它防篡改）
- 凭证是**流程证据，不是防篡改证明**：任何有 `refs/notes/orchestra-review` 推送权限的人都能伪造。要更强：把「谁能推 `refs/notes/*`」当作信任边界来管（平台能不能保护这个 ref 取决于平台，先确认），或自行给 notes 提交加签名。
- **套件必须已经在目标分支上**——可信副本取自那里。装套件的那个 PR 自己没有可信副本可跑：第一次装请由有权限的人直接推到默认分支，或这一个 PR 由人工放行。
- CI 的检出要有完整历史和目标分支的远端跟踪 ref（`fetch-depth: 0` / `GIT_DEPTH: 0`）；浅克隆算不出合并基点会退出 4。需要 git ≥ 2.29（`fetch --no-write-fetch-head`）。
- 来自 fork 的 PR：凭证要发布到 CI 取凭证的那个远端（`origin`），fork 作者没有推送权限——这种 PR 要由有权限的人在本机复核后 `publish`；上面的 GitHub 示例没有覆盖 fork。
- 它只验证「这份内容有人审过/放行过」，不验证审得对不对。
