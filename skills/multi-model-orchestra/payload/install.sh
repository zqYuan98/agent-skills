#!/usr/bin/env bash
# install.sh —— 把这套多模型编排装进一个目标仓库（项目级：自包含、可提交、CI 可用；不碰你的全局配置）。
#
# 用法：bash install.sh [--git-hook] [--dry-run] [--force] <目标仓库目录>
#   --git-hook  同时安装 git pre-push 审查门（没过审查的分支推不上去）
#   --dry-run   只打印会做什么，不改任何东西
#   --force     套件里「你可能改过」的文件（配置/提示词/Skill/规则）也覆盖；默认不覆盖
#
# 装了什么：
#   .orchestra/            脚本、提示词、规则、模型档位（orchestra.conf）、守卫钩子
#   .claude/skills/        5 个 Skill
#   .claude/settings.json  合并进守卫钩子（已有的钩子和设置原样保留）
#   CLAUDE.md              追加一行 @.orchestra/rules.md（已有内容原样保留）
#   .gitignore / .gitattributes  忽略运行记录；脚本强制 LF（Windows 上否则 Git Bash 里会报 \r）
# 幂等：重复运行安全。「套件自带」的脚本每次覆盖；「你可能改过」的文件已存在且不同则保留你的、新版另存为 .kit-new。
# 任何一步失败都如实失败（非 0），并且不会去装 git 钩子——钩子找不到门禁脚本就会放行，那比没装更糟。
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$KIT/.orchestra/lib/common.sh"

DRY=0; FORCE=0; GITHOOK=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --git-hook) GITHOOK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "用法：bash install.sh [--git-hook] [--dry-run] [--force] <目标仓库目录>" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "目标目录不存在：$TARGET" >&2; exit 2; }
T=$(cd "$TARGET" && pwd)
[ "$T" != "$KIT" ] || { echo "目标就是套件自己，不用装。" >&2; exit 2; }

say() { printf '%s\n' "$*"; }
FAIL=0
fail() { say "  ✗ $*"; FAIL=1; }
[ "$DRY" -eq 1 ] && say "【dry-run】以下只是预演，不会改动任何文件。"
say "安装到：$T"
IS_GIT=0; ( cd "$T" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) && IS_GIT=1
[ "$IS_GIT" -eq 1 ] || say "  ⚠ 目标不是 git 仓库：审查门、worktree 派活都需要 git。先 git init。"
# --git-hook：钩子在【仓库根】找 .orchestra，所以必须是 git 仓库、且目标就是仓库根——否则装完钩子找不到门脚本。预检失败什么都不写。
if [ "$GITHOOK" -eq 1 ]; then
  if [ "$IS_GIT" -ne 1 ]; then
    say "  ✗ 要求了 --git-hook，但目标不是 git 仓库（什么都没写）。先 git init，或去掉 --git-hook。"; exit 1
  fi
  GTOP=$(cd "$T" && cd "$(git rev-parse --show-toplevel)" && pwd)
  if [ "$GTOP" != "$T" ]; then
    say "  ✗ --git-hook 必须对【仓库根目录】运行（什么都没写）：这里的仓库根是 $GTOP。钩子只在仓库根找 .orchestra，装在子目录它找不到。"; exit 1
  fi
fi

# ── 0 预检：要建目录的位置上已经有同名【文件】→ 一个字节都不写，直接失败 ─────────────
SKILLS="dual-plan copy-advisor codex-delegate review-gate error-to-check"
BLOCKED=""
for p in .orchestra .orchestra/bin .orchestra/lib .orchestra/hooks .orchestra/githooks .orchestra/prompts .claude .claude/skills \
         $(for s in $SKILLS; do echo ".claude/skills/$s"; done); do
  if [ -e "$T/$p" ] && [ ! -d "$T/$p" ]; then BLOCKED="$BLOCKED $p"; fi
done
if [ -n "$BLOCKED" ]; then
  say "  ✗ 目标里这些路径已存在但不是目录，没法安装（什么都没写）：$BLOCKED"
  say "    先把它们挪走或改名，再重跑。"
  exit 1
fi

# ── 1 套件自带的代码：每次覆盖 ────────────────────────────────────────
say "[1/6] 脚本与钩子（套件自带，覆盖）"
for d in bin lib hooks githooks; do
  if [ "$DRY" -eq 0 ]; then
    if mkdir -p "$T/.orchestra/$d" && cp -R "$KIT/.orchestra/$d/." "$T/.orchestra/$d/"; then say "  ✓ .orchestra/$d/"
    else fail ".orchestra/$d/ 复制失败"; fi
  else
    say "  ✓ .orchestra/$d/"
  fi
done
if [ "$DRY" -eq 0 ]; then
  chmod +x "$T"/.orchestra/bin/* "$T"/.orchestra/githooks/* 2>/dev/null
  for f in bin/review-gate-check bin/codex-review bin/codex-worker bin/agy-ask bin/ratchet bin/notify-feishu lib/common.sh lib/review.sh lib/verdict.mjs hooks/guard.mjs githooks/pre-push; do
    [ -f "$T/.orchestra/$f" ] || fail "装完后缺少 .orchestra/$f"
  done
fi

# ── 2 你可能改过的文件：不静默覆盖 ────────────────────────────────────
put_tunable() { # put_tunable <相对套件根的路径>
  local rel=$1 src="$KIT/$1" dst="$T/$1"
  if [ ! -e "$dst" ] || [ "$FORCE" -eq 1 ]; then
    if [ "$DRY" -eq 0 ]; then
      if mkdir -p "$(dirname "$dst")" && cp "$src" "$dst"; then say "  ✓ $rel"; else fail "$rel 复制失败"; fi
    else say "  ✓ $rel"; fi
  elif cmp -s "$src" "$dst"; then
    say "  = $rel（与套件一致）"
  else
    if [ "$DRY" -eq 0 ]; then cp "$src" "$dst.kit-new" || fail "$rel.kit-new 写入失败"; fi
    say "  ⚠ $rel 已存在且与套件版不同 → 保留你的版本；套件新版另存为 $rel.kit-new（自己 diff 后取舍）"
  fi
}
say "[2/6] 配置 / 提示词 / 规则 / Skill（你可能改过：不静默覆盖）"
for rel in .orchestra/orchestra.conf .orchestra/rules.md .orchestra/sensitive-paths.example \
           .orchestra/prompts/gemini-plan.md .orchestra/prompts/gemini-copy.md .orchestra/prompts/codex-worker.md \
           .orchestra/prompts/codex-review.md .orchestra/prompts/codex-review-reround.md .orchestra/prompts/review.schema.json \
           $(for s in $SKILLS; do echo ".claude/skills/$s/SKILL.md"; done); do
  put_tunable "$rel"
done

# ── 3 合并守卫钩子进 .claude/settings.json ────────────────────────────
say "[3/6] 守卫钩子 → .claude/settings.json（合并，不覆盖已有设置）"
MERGE_JS='
const fs=require("fs"),path=require("path");const [p,dry]=[process.argv[1],process.argv[2]==="dry"];
let j={};
if(fs.existsSync(p)){try{j=JSON.parse(fs.readFileSync(p,"utf8")||"{}");}catch(e){console.log("INVALID");process.exit(3);}}
j.hooks=j.hooks||{};j.hooks.PreToolUse=j.hooks.PreToolUse||[];
const cmd="node \"$CLAUDE_PROJECT_DIR/.orchestra/hooks/guard.mjs\"";
if(j.hooks.PreToolUse.some(e=>(e.hooks||[]).some(h=>h.command===cmd))){console.log("UNCHANGED");process.exit(0);}
if(!dry){j.hooks.PreToolUse.push({matcher:"Bash",hooks:[{type:"command",command:cmd}]});fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");}
console.log("MERGED");'
need_cmd node "Codex 本身依赖 Node；没有就装 Node"
RES=$(node -e "$MERGE_JS" "$(to_native "$T/.claude/settings.json")" "$([ "$DRY" -eq 1 ] && echo dry || echo run)" 2>&1); RC=$?
case "$RES" in
  UNCHANGED) say "  = 已注册，无需改动" ;;
  MERGED)    say "  ✓ 已注册 PreToolUse(Bash) → .orchestra/hooks/guard.mjs" ;;
  INVALID)   say "  ✗ $T/.claude/settings.json 不是合法 JSON，已中止（没有改动它）"; exit 4 ;;
  *)         fail ".claude/settings.json 合并失败：$RES" ;;
esac
[ "$RC" -eq 0 ] || [ "$RES" = INVALID ] || FAIL=1

# ── 4 CLAUDE.md：只追加一行引入 ───────────────────────────────────────
say "[4/6] CLAUDE.md 引入规则"
CM="$T/CLAUDE.md"
if [ -f "$CM" ] && grep -qF '@.orchestra/rules.md' "$CM"; then
  say "  = 已引入"
elif [ "$DRY" -eq 1 ]; then
  say "  ✓ 追加：@.orchestra/rules.md（原有内容原样保留）"
else
  if { [ -s "$CM" ] && printf '\n'; printf '<!-- orchestra:begin -->\n@.orchestra/rules.md\n<!-- orchestra:end -->\n'; } >> "$CM"; then
    say "  ✓ 追加：@.orchestra/rules.md（原有内容未动）"
  else fail "CLAUDE.md 写入失败"; fi
fi

# ── 5 .gitignore / .gitattributes ────────────────────────────────────
say "[5/6] .gitignore / .gitattributes"
ensure_line() { # ensure_line <文件> <整行内容>
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  if [ "$DRY" -eq 0 ]; then
    { [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && printf '\n'; printf '%s\n' "$2"; } >> "$1" || { fail "$(basename "$1") 写入失败"; return 0; }
  fi
  say "  ✓ $(basename "$1") += $2"
}
ensure_line "$T/.gitignore" ".orchestra/runs/"
for line in ".orchestra/bin/* text eol=lf" ".orchestra/lib/* text eol=lf" ".orchestra/githooks/* text eol=lf" ".orchestra/hooks/* text eol=lf"; do
  ensure_line "$T/.gitattributes" "$line"
done

# ── 6 git pre-push 审查门（可选）─────────────────────────────────────
say "[6/6] git pre-push 审查门"
if [ "$GITHOOK" -ne 1 ]; then
  say "  - 未请求（加 --git-hook 安装）"
elif [ "$IS_GIT" -ne 1 ]; then
  say "  ✗ 不是 git 仓库，跳过"
elif [ "$FAIL" -ne 0 ]; then
  say "  ✗ 前面有步骤失败，不装 git 钩子（门禁脚本没装好，钩子只会放行——比没有更糟）"
else
  HP=$(cd "$T" && git config --get core.hooksPath || true)
  HD=$(cd "$T" && git rev-parse --path-format=absolute --git-common-dir)/hooks
  # .git/hooks/pre-push 只是个转发桩（带 orchestra-stub 标记）：门逻辑在仓库里的 .orchestra/githooks/pre-push，
  # 随套件更新、不用再动 .git/hooks；也因此我们只会覆盖「自己的桩」，绝不碰用户自己写的钩子。
  STUB='#!/usr/bin/env bash
# orchestra-stub: 转发到 .orchestra/githooks/pre-push（门逻辑随套件更新；这个桩本身不用改）
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
impl="$top/.orchestra/githooks/pre-push"
if [ ! -f "$impl" ]; then   # linked worktree 可能是从装套件之前的提交建的：回退到主工作区的套件
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  impl="$(dirname "$common")/.orchestra/githooks/pre-push"
fi
if [ ! -f "$impl" ]; then   # 套件找不到：不静默放行（静默放行等于门悄悄没了）
  echo "审查门 ⛔ 找不到 .orchestra/githooks/pre-push（套件被删了，或这个检出里没有）。为不静默放行，推送已拦下。" >&2
  echo "  把套件提交进该分支，或运行 install.sh 重装；确认不需要审查的用户本人可以 git push --no-verify。" >&2
  exit 1
fi
exec bash "$impl" "$@"'
  CHAIN='接法（必须放在你的 pre-push【最前面】——它要读标准输入；你自己的逻辑如需读 ref 输入，请改读 $refs）：
        refs=$(cat); printf "%s\n" "$refs" | bash .orchestra/githooks/pre-push "$@" || exit 1'
  if [ -n "$HP" ]; then
    say "  ⚠ 你设置了 core.hooksPath=$HP（husky 之类），未覆盖、也没往里装。$CHAIN"
  elif [ -e "$HD/pre-push" ] && ! sed -n 2p "$HD/pre-push" | grep -q '^# orchestra-stub:'; then
    say "  ⚠ $HD/pre-push 已存在且不是本套件的转发桩，未覆盖。$CHAIN"
  elif [ "$DRY" -eq 1 ]; then
    say "  ✓ 将安装转发桩 $HD/pre-push"
  else
    if mkdir -p "$HD" && printf '%s\n' "$STUB" > "$HD/pre-push" && chmod +x "$HD/pre-push"; then
      say "  ✓ $HD/pre-push（转发桩；没过审查的分支推不上去；绕过只能用户本人 --no-verify）"
    else fail "pre-push 钩子安装失败"; fi
  fi
  # 基线分支要有明确依据：审查门拿它判断「这次推送改了什么」。猜出来的基线若就是被推送的分支自己，门会拦住。
  BCUR=$(cd "$T" && git config --get orchestra.base || true)
  if [ -n "$BCUR" ]; then
    say "  = 基线分支已配置：$BCUR"
  elif ( cd "$T" && git symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1 ); then
    say "  = 基线取自 origin/HEAD"
  else
    CUR=$(cd "$T" && git symbolic-ref --short -q HEAD || true)
    case "$CUR" in
      main|master|trunk)
        if [ "$DRY" -eq 1 ]; then say "  ✓ 将设置 git config orchestra.base=$CUR"
        elif ( cd "$T" && git config orchestra.base "$CUR" ); then say "  ✓ 已设置 git config orchestra.base=$CUR（让审查门有明确的基线；不对就改）"
        else fail "设置 orchestra.base 失败"; fi ;;
      *) say "  ⚠ 没法确定基线分支（当前在「${CUR:-?}」）：请执行 git config orchestra.base <默认分支名>，否则审查门会拦住并提示你" ;;
    esac
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  say ""; say "✗ 安装未完成（见上面标 ✗ 的步骤）。修好后可以直接重跑，幂等。"
  exit 1
fi
cat <<EOF

完成。接下来（在 $T 里）：
  1. 把 .orchestra/ .claude/ CLAUDE.md .gitignore .gitattributes 提交进仓库。
  2. 看 .orchestra/orchestra.conf：模型档位（Gemini 的 id 要跟你账号对得上：bash .orchestra/bin/agy-ask --doctor）。
  3. 敏感路径：cp .orchestra/sensitive-paths.example .orchestra/sensitive-paths 然后按仓库改（决定哪些文件审查用 xhigh）。
  4. 基线分支认不出时（默认分支不叫 main/master/trunk/develop，又没设 origin/HEAD）：git config orchestra.base <分支名>
  5. 体检：bash .orchestra/bin/codex-worker --doctor
EOF
