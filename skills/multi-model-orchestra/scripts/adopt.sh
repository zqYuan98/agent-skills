#!/usr/bin/env bash
# adopt.sh —— 把本技能自带的「多模型编排套件」装进一个项目。等价于在套件仓库里跑 install.sh：
# 技能包里的文件是为分发改过名的（没有隐藏目录、没有嵌套的 SKILL.md），这里先还原成套件的目录布局，再交给 install.sh。
#
# 用法：bash adopt.sh [--git-hook] [--dry-run] [--force] <目标仓库目录>
#   --git-hook  同时安装 git pre-push 审查门（没过审查的分支推不上去）；目标必须是 git 仓库根
#   --dry-run   只打印会做什么，不改任何东西
#   --force     套件里「你可能改过」的文件（配置/提示词/Skill/规则）也覆盖；默认不覆盖
# 退出码与 install.sh 相同：0 成功 | 1 安装失败 | 2 用法错/目标不存在/技能包不完整 | 4 settings.json 不是合法 JSON
set -uo pipefail
SK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$SK/payload"
case "${1:-}" in -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

for need in install.sh orchestra/bin orchestra/lib orchestra/rules.md skills; do
  [ -e "$P/$need" ] || { echo "技能包不完整：缺少 payload/$need（请重新导入技能包）" >&2; exit 2; }
done
KT=$(mktemp -d) || { echo "建不了临时目录" >&2; exit 2; }
trap 'rm -rf "$KT"' EXIT

# 还原成套件仓库的目录布局：payload/orchestra → .orchestra，payload/skills/<名字>.md → .claude/skills/<名字>/SKILL.md
mkdir -p "$KT/.orchestra" "$KT/.claude/skills" || exit 2
cp -R "$P/orchestra/." "$KT/.orchestra/" || exit 2
for f in "$P"/skills/*.md; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .md)
  mkdir -p "$KT/.claude/skills/$n" && cp "$f" "$KT/.claude/skills/$n/SKILL.md" || exit 2
done
cp "$P/install.sh" "$KT/install.sh" || exit 2

bash "$KT/install.sh" "$@"
