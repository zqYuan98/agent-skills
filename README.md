# agent-skills

我的 Agent 技能合集。一个技能一个文件夹：`skills/<名字>/SKILL.md`（SKILL.md 格式，CC Switch 可以直接装）。

## 技能

| 技能 | 做什么 | 怎么用 |
|---|---|---|
| [multi-model-orchestra](skills/multi-model-orchestra/SKILL.md) | 把「Claude 总指挥＋Gemini 军师＋Codex 工兵/守门人」的多模型编排套件装进当前项目：常驻规则、5 个子技能、守卫钩子、合并前审查门 | 新项目里对 Claude 说「接入编排」；装好后在该项目里新开会话才生效。需要 bash、git、node |

## 安装

**CC Switch（从仓库）**
1. Skills 页 → 右上角 ⋯ → 仓库管理
2. 「仓库 URL」填 `<你的 GitHub 用户名>/agent-skills`，分支 `main`，**Skill path 填 `skills`** → 添加仓库
3. 发现 → 来源选「仓库」→ 找到技能 →「安装到」勾 Claude Code → 安装

仓库是私有的时候，CC Switch 要有访问令牌才读得到；没配就改成公开，或者用下面的手动复制。

**手动**：把 `skills/<名字>/` 整个文件夹复制到 `~/.claude/skills/<名字>/`（只给某个项目用，就放到 `<项目>/.claude/skills/<名字>/`）。

## 往里加新技能
1. 新建 `skills/<名字>/SKILL.md`，开头写 `name:`（与文件夹同名）和 `description:`（什么时候该用它）。
2. 文件夹里别放 `.` 开头的文件或目录、符号链接、嵌套的 `SKILL.md`——CC Switch 对它们的处理没有文档，保守起见一律不带。
3. 文件夹名在整个仓库里不要重名（CC Switch 按文件夹名判重）。
4. 在上面的表格里加一行。
5. `.sh` 脚本必须是 LF 换行（`.gitattributes` 已经统一成 LF）。
