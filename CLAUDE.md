# agent-skills（本仓库）

我的 Agent 技能合集：`skills/<名字>/SKILL.md`，一个技能一个文件夹。给人看的说明在 `README.md`。

## 往里加或改技能时的约定
- 每个技能放 `skills/<名字>/SKILL.md`：frontmatter 里 `name` 与文件夹同名、必须有 `description`；文件夹名在整个仓库里不重名（CC Switch 按文件夹名判重）。
- 技能文件夹里不放 `.` 开头的文件或目录、符号链接、嵌套的 `SKILL.md`（CC Switch 对它们的处理没有文档）。需要隐藏目录的内容，改名放进普通目录，装的时候由脚本还原（例子：`multi-model-orchestra/scripts/adopt.sh`）。
- 脚本一律 LF（`.gitattributes` 已强制）。`.sh` 在 git 里设成可执行：`git update-index --chmod=+x <文件>`。
- 加了技能就在 `README.md` 的技能表里加一行。
- 不放个人信息：用户名、邮箱、本机路径、令牌、密钥。

## 提交（隐私约束，别漏）
- 提交必须带固定日期，不让 git 写入本机的时间和时区：
  `GIT_AUTHOR_DATE='@315532800 +0000' GIT_COMMITTER_DATE='@315532800 +0000' git commit …`（固定为 1980-01-01 00:00:00 UTC）。
- 提交身份用 GitHub 的 noreply 邮箱（本仓库已在本地配好 `user.name` / `user.email`），不用真实邮箱。
- 推送的凭据只放进一次性的环境变量配置（`GIT_CONFIG_COUNT` ＋ `http.extraHeader`），不写进 `.git/config`、不写进远端地址、不打印。

## 来源
`skills/multi-model-orchestra/` 是「多模型编排套件」源码里 `dist/multi-model-orchestra/` 的逐字节拷贝（生成物）：要改它，去套件源码里改并重新打包，再整个目录同步过来，别在这里手改。
