#!/usr/bin/env bash
# .orchestra/lib/review.sh —— 审查门的共享逻辑，被 codex-review / review-gate-check source。
#
# 审查记录绑定「树 + 基线」而不是提交号：只改提交说明、amend 不改内容时，不用重新付一次审查的钱。
# 状态存在 `.git/orchestra/review/`（所有 worktree 共享、不入库、不污染工作区）。

[ -n "${_ORCH_REVIEW_LOADED:-}" ] && return 0
_ORCH_REVIEW_LOADED=1

# 基线只能由本库自己决定：继承来的环境变量 BASE / BASE_SRC / BASE_OVERRIDE 一律作废——
# 否则 BASE=HEAD 之类的就能让门以为「相对基线没有任何改动」而放行。
# 命令行的 --base 由 codex-review 经 BASE_OVERRIDE 传进来（source 之后才设）。
unset BASE BASE_SRC BASE_OVERRIDE

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 配置里写的是裸分支名（main）、而 origin 有它的远端副本（origin/main）时，用远端副本：
# 本地 main 可能带着还没推的未审提交，拿它当基线就成了「自己跟自己比」，直推 main 的未审提交就漏过去了。
# 想强制用本地分支，写成 refs/heads/main。
_upgrade_base() {
  case "$BASE" in refs/*) return 0 ;; esac
  git show-ref --verify -q "refs/heads/$BASE" 2>/dev/null || return 0     # 不是本地分支名（比如已经是 origin/x）：照用
  git rev-parse --verify -q "refs/remotes/origin/$BASE^{commit}" >/dev/null 2>&1 && BASE="origin/$BASE"
  return 0
}

# 找基线分支；找不到返回 1（不退出）。同时设置 BASE_SRC：explicit（有明确依据）或 inferred（猜的）。
# 优先级：--base(BASE_OVERRIDE) > ORCH_BASE > git config orchestra.base > origin/HEAD  ← 以上都是 explicit
#         > origin/{main,master,trunk,develop} > 本地同名分支                    ← 这些是 inferred
# 每次都从头算（BASE 不当输入用）：同一个仓库状态得出同一个结果。
resolve_base_quiet() {
  BASE=${BASE_OVERRIDE:-}
  if [ -n "$BASE" ]; then BASE_SRC=explicit; _upgrade_base; return 0; fi
  BASE=${ORCH_BASE:-}
  if [ -n "$BASE" ]; then BASE_SRC=explicit; _upgrade_base; return 0; fi
  BASE=$(git config --get orchestra.base 2>/dev/null || true)
  if [ -n "$BASE" ]; then BASE_SRC=explicit; _upgrade_base; return 0; fi
  local c
  c=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$c" ] && { BASE=$c; BASE_SRC=explicit; return 0; }
  for c in origin/main origin/master origin/trunk origin/develop main master trunk develop; do
    git rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1 && { BASE=$c; BASE_SRC=inferred; return 0; }
  done
  BASE=""; BASE_SRC=""
  return 1
}

BASE_HELP="设置其一：git config orchestra.base <分支名>　或　export ORCH_BASE=<分支名>　或　git remote set-head origin -a"

resolve_base() {
  resolve_base_quiet || { DIE_CODE=4; die "找不到基线分支。$BASE_HELP"; }
}

# 进入仓库根并确定「审查键」。
# 设置：TOP STATE_DIR BRANCH BKEY STATE_FILE LAST_FILE PENDING_FILE BASE BASE_SRC HEAD_SHA MB TREE KEY OK_FILE SELF_BASE
# $1 可选：要审的提交（默认 HEAD）；$2 可选：被推送/被审的目标分支名（默认当前分支，可带 refs/heads/ 前缀）
# SELF_BASE=1 表示：基线是猜出来的，而被审的提交相对它「没有任何改动」——这个「没有」不可信：
# 比如默认分支其实叫 release，本地 develop 却被猜成了基线，develop 跟自己比当然没有改动，
# 不管最后推到哪个远端分支名下。调用方必须拦住并要求显式配置。基线有明确依据（配置/环境变量/origin/HEAD）时不受此限。
review_ctx_init() {
  need_cmd git
  TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { DIE_CODE=4; die "不在 git 仓库里"; }
  cd "$TOP" || exit 4
  STATE_DIR="$(git rev-parse --path-format=absolute --git-common-dir)/orchestra/review"
  mkdir -p "$STATE_DIR"
  BRANCH=$(git symbolic-ref --short -q HEAD || echo detached)
  BKEY=${BRANCH//\//__}
  STATE_FILE="$STATE_DIR/branch.$BKEY"
  LAST_FILE="$STATE_DIR/last.$BKEY.json"
  PENDING_FILE="$STATE_DIR/pending.$BKEY"
  resolve_base
  HEAD_SHA=$(git rev-parse "${1:-HEAD}^{commit}" 2>/dev/null) || { DIE_CODE=4; die "无法解析提交：${1:-HEAD}"; }
  MB=$(git merge-base "$BASE" "$HEAD_SHA" 2>/dev/null) || { DIE_CODE=4; die "无法计算与 $BASE 的合并基点（是浅克隆吗？审查门要完整历史：CI 里 GitHub 用 fetch-depth: 0，GitLab 用 GIT_DEPTH: 0）"; }
  REVIEW_BRANCH=${2:-$BRANCH}; REVIEW_BRANCH=${REVIEW_BRANCH#refs/heads/}
  SELF_BASE=0
  if [ "$MB" = "$HEAD_SHA" ] && [ "${BASE_SRC:-}" = inferred ]; then SELF_BASE=1; fi
  TREE=$(git rev-parse "$HEAD_SHA^{tree}")
  KEY="${TREE}-${MB:0:12}"
  OK_FILE="$STATE_DIR/ok.$KEY"
}

# 读取本分支的轮次状态：ROUNDS_USED EXTRA LAST_TREE MAX_ALLOWED
st_read() {
  ROUNDS_USED=0; EXTRA=0; LAST_TREE=""
  if [ -f "$STATE_FILE" ]; then
    ROUNDS_USED=$(sed -n 's/^rounds_used=//p' "$STATE_FILE" | head -1)
    EXTRA=$(sed -n 's/^extra_rounds=//p' "$STATE_FILE" | head -1)
    LAST_TREE=$(sed -n 's/^last_tree=//p' "$STATE_FILE" | head -1)
  fi
  ROUNDS_USED=${ROUNDS_USED:-0}; EXTRA=${EXTRA:-0}
  MAX_ALLOWED=$(( ${REVIEW_MAX_ROUNDS:-2} + EXTRA ))
}

# st_write <已用轮数> <额外轮数> [最后一次被拦的树]
st_write() { printf 'rounds_used=%s\nextra_rounds=%s\nlast_tree=%s\n' "$1" "$2" "${3:-}" > "$STATE_FILE"; }

# 一轮周期结束（通过或被人放行）→ 计数清零
st_reset() { st_write 0 0 ""; rm -f "$LAST_FILE" "${LAST_FILE%.json}.md" "$PENDING_FILE"; }

# 审计：只追加、不带时间戳（顺序即先后）。放行/再审的「用户原话」必须落在这里，不能只打印到终端。
audit() { printf '%s\n' "$*" >> "$STATE_DIR/audit.log"; }

# 「审查请求」：prompt 生成提示词时记下审的是哪份内容；record 回填结论时必须对得上，
# 否则就会出现「审的是 A、结论记到了 B 上」。
# 每次 prompt 发一个请求ID（REQ_ID）；record 必须带同一个 --request，迟到的旧结论就记不到新请求头上。
pending_write() {
  printf 'req=%s\ntree=%s\nmb=%s\nhead=%s\nround=%s\neffort=%s\nmodel=%s\n' "$REQ_ID" "$TREE" "$MB" "$HEAD_SHA" "$ROUND" "$EFFORT" "$MODEL" > "$PENDING_FILE"
}
# 读取到 P_REQ P_TREE P_MB P_ROUND P_EFFORT P_MODEL；没有请求返回 1
pending_load() {
  [ -f "$PENDING_FILE" ] || return 1
  P_REQ=$(sed -n 's/^req=//p' "$PENDING_FILE" | head -1)
  P_TREE=$(sed -n 's/^tree=//p' "$PENDING_FILE" | head -1);   P_MB=$(sed -n 's/^mb=//p' "$PENDING_FILE" | head -1)
  P_ROUND=$(sed -n 's/^round=//p' "$PENDING_FILE" | head -1); P_EFFORT=$(sed -n 's/^effort=//p' "$PENDING_FILE" | head -1)
  P_MODEL=$(sed -n 's/^model=//p' "$PENDING_FILE" | head -1)
  [ -n "$P_REQ" ] && [ -n "$P_TREE" ] && [ -n "$P_MB" ] && [ -n "$P_ROUND" ]
}

# 相对基点改了哪些文件（一行一个）。-z + core.quotepath=false：非 ASCII 路径不会被 git 加引号转义。
changed_files() {
  local f
  git -c core.quotepath=false diff --name-only -z "$MB" "$HEAD_SHA" 2>/dev/null | while IFS= read -r -d '' f; do printf '%s\n' "$f"; done
}

# 命中敏感路径的文件 → 深档审查。输出命中的文件（一行一个）。
sensitive_hits() {
  local pf="$TOP/.orchestra/sensitive-paths" patterns f p
  [ -f "$pf" ] || pf="$ORCH_HOME/sensitive-paths.example"
  patterns=$(grep -vE '^[[:space:]]*(#|$)' "$pf" 2>/dev/null || true)
  [ -n "$patterns" ] || return 0
  shopt -s nocasematch
  while IFS= read -r f; do
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      # shellcheck disable=SC2053
      if [[ $f == $p ]]; then printf '%s\n' "$f"; break; fi
    done <<<"$patterns"
  done < <(changed_files)
  shopt -u nocasematch
}

# ── 审查凭证（git notes）：让「这份内容过了审查」随仓库走，CI 才看得到 ──────────────────
# 本机的审查记录在 .git/orchestra/，CI 看不见；凭证用 git notes（refs/notes/orchestra-review）发布，不依赖任何托管平台。
#   · 挂在【tree 对象】上——和审查键一样按「内容」绑定，不按提交号（amend/rebase 后内容没变，凭证照样有效）；
#   · 一次审查追加一段（空行分隔）：key=<树>-<基点前12位>、status=pass|approved、轮次、模型、推理档；
#     放行的还带 by_ref=<审计引用>——【不带用户原话】：凭证会被推到远端、被 CI 打印，原话（可能有姓名、邮箱、时间）只留在本机 audit.log；
#   · 不带时间戳；notes 提交的身份是中性的 orchestra、日期固定为 2000-01-01 UTC，reflog 也不建——
#     不能把用户的本地时间/时区/姓名邮箱带出去。
# 局限：任何有该 ref 推送权限的人都能伪造凭证；它是「流程证据」，不是防篡改证明（要更强请保护这个 ref 或签名）。
ATTEST_REF=orchestra-review

# 凡是会更新 ref 的 git 操作（notes、fetch、update-ref）都走这里：
#   · 身份与日期固定——调用者的姓名、邮箱、本地时间、时区不会写进 notes 提交，也不会写进 reflog；
#   · core.logAllRefUpdates=false——不为这些 ref 新建 reflog（reflog 里记的就是调用者的身份和本地时间）。
_ag() {
  GIT_AUTHOR_NAME=orchestra GIT_AUTHOR_EMAIL=orchestra@invalid.invalid GIT_COMMITTER_NAME=orchestra GIT_COMMITTER_EMAIL=orchestra@invalid.invalid \
  GIT_AUTHOR_DATE='946684800 +0000' GIT_COMMITTER_DATE='946684800 +0000' git -c core.logAllRefUpdates=false "$@"
}

# 凭证 ref 的写入、以及发布时的合并必须串行：多个 worktree 同时 `git notes append`，会各自读到旧的 notes 树、
# 各自提交，后写的覆盖先写的，而且双方都报成功。锁放在 git 公共目录里（所有 worktree 共享）。
# 用 mkdir 当锁（原子）；持锁的进程崩了留下的锁，靠 pid 判活清掉——不查时间，也就不碰系统时钟。
_attest_lock() {
  local dir holder n=0 nopid=0
  dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/orchestra" || return 1
  mkdir -p "$dir" || return 1
  ATTEST_LOCK="$dir/notes.lock"
  until mkdir "$ATTEST_LOCK" 2>/dev/null; do
    holder=$(cat "$ATTEST_LOCK/pid" 2>/dev/null || true)
    if [ -n "$holder" ]; then
      if ! kill -0 "$holder" 2>/dev/null; then
        # 持锁者已经不在了：只清【还是这个死 pid】的锁，别误删别人刚拿到的
        [ "$(cat "$ATTEST_LOCK/pid" 2>/dev/null || true)" = "$holder" ] && rm -rf "$ATTEST_LOCK"
        continue
      fi
    else
      # 刚建好锁、还没来得及写 pid 是常态（毫秒级）；久久没有 pid 说明建锁的进程半路死了
      nopid=$((nopid + 1)); [ "$nopid" -gt 50 ] && { rm -rf "$ATTEST_LOCK"; continue; }
    fi
    n=$((n + 1)); [ "$n" -ge 300 ] && { ATTEST_LOCK=""; return 1; }       # 等了约 30 秒还拿不到：放弃
    sleep 0.1
  done
  printf '%s' "$$" > "$ATTEST_LOCK/pid"
}
_attest_unlock() { [ -n "${ATTEST_LOCK:-}" ] && rm -rf "$ATTEST_LOCK"; ATTEST_LOCK=""; return 0; }

# attest_find <树> <key> [notes-ref] [status]：在这棵树的凭证里找 key 匹配、且 status 合格的那一段；找到就打印并返回 0。
# status 留空 = pass 或 approved 都算。notes-ref 留空 = 本地 refs/notes/orchestra-review；
# CI 核验读它单独取回的 ref（见 review-gate-check --ci）。
attest_find() {
  local note
  note=$(git notes --ref="${3:-$ATTEST_REF}" show "$1" 2>/dev/null) || return 1
  printf '%s\n' "$note" | awk -v key="key=$2" -v want="${4:-}" '
    BEGIN { RS = ""; FS = "\n" }
    { hit = 0; ok = 0
      for (i = 1; i <= NF; i++) {
        if ($i == key) hit = 1
        if (want == "") { if ($i == "status=pass" || $i == "status=approved") ok = 1 }
        else if ($i == "status=" want) ok = 1
      }
      if (hit && ok) { print; found = 1; exit } }
    END { exit found ? 0 : 1 }'
}

# _attest_append <树> <key> <status> <轮次> <模型> <推理档> [审计引用]：给这棵树追加一段凭证（调用方必须持锁）。
# 同一段（同 key、同 status）已经有了就不再追加——重复补写不会让它越攒越长。
_attest_append() {
  local body
  attest_find "$1" "$2" "" "$3" >/dev/null 2>&1 && return 0
  body=$(printf 'orchestra-review v1\nkey=%s\nstatus=%s\nround=%s\nmodel=%s\neffort=%s' "$2" "$3" "$4" "$5" "$6")
  [ -n "${7:-}" ] && body+=$'\n'"by_ref=$7"
  _ag notes --ref="$ATTEST_REF" append -m "$body" "$1" >/dev/null 2>&1
}

# attest_write <pass|approved> [审计引用]：为当前 TREE/KEY 追加一段凭证。失败只警告，不影响本机放行
# （publish 时会从本机的通过记录补写）。
attest_write() {
  local rc
  if ! _attest_lock; then
    warn "拿不到凭证锁（别的进程占着）——这次没写入审查凭证；codex-review publish 会从本机的通过记录补写"; return 0
  fi
  _attest_append "$TREE" "$KEY" "$1" "${ROUND:-0}" "${MODEL:-}" "${EFFORT:-}" "${2:-}"; rc=$?
  _attest_unlock
  [ $rc -eq 0 ] || warn "没能写入审查凭证（git notes）——CI 将看不到这次审查；codex-review publish 会尝试从本机的通过记录补写"
  return 0
}

# _attest_ok_keys：本地凭证里所有「status 合格（pass/approved）」的 key，一行一个。
# 一次读完所有凭证（git cat-file --batch 一个进程），不是每棵树起一个 git 进程——凭证攒到几百棵树也不慢。
_attest_ok_keys() {
  git notes --ref="$ATTEST_REF" list 2>/dev/null | awk '{print $1}' | git cat-file --batch 2>/dev/null | awk '
    /^orchestra-review v1$/ { key = ""; ok = 0; next }
    /^key=/                 { key = substr($0, 5) }
    /^status=(pass|approved)$/ { ok = 1 }
    { if (key != "" && ok) { print key; key = ""; ok = 0 } }'
}

# attest_sync：本机的通过/放行记录（ok.*）是凭证的依据；凭证丢了（被误删、被覆盖、当时没写成），按记录补回来。
# 调用方必须持锁。已经有的不动（幂等）。
attest_sync() {
  local f key tree st round model effort ref have
  have=$'\n'"$(_attest_ok_keys)"$'\n'
  for f in "$STATE_DIR"/ok.*; do
    [ -f "$f" ] || continue
    key=${f##*/ok.}
    printf '%s' "$key" | grep -Eq '^[0-9a-f]{40,64}-[0-9a-f]{12}$' || continue
    case "$have" in *$'\n'"$key"$'\n'*) continue ;; esac               # 凭证里已经有了
    tree=${key%%-*}
    git cat-file -e "$tree^{tree}" 2>/dev/null || continue            # 这棵树已经不在仓库里（被清理了）：补了也没用
    st=$(sed -n 's/^status=//p' "$f" | head -1)
    case "$st" in pass|approved) ;; *) continue ;; esac
    round=$(sed -n 's/^round=//p' "$f" | head -1);  [ -n "$round" ] || round=$(sed -n 's/^rounds_used=//p' "$f" | head -1)
    model=$(sed -n 's/^model=//p' "$f" | head -1);  effort=$(sed -n 's/^effort=//p' "$f" | head -1)
    ref=$(sed -n 's/^ref=//p' "$f" | head -1)
    _attest_append "$tree" "$key" "$st" "${round:-0}" "$model" "$effort" "$ref" || warn "补写凭证失败：$key"
  done
  return 0
}

# _attest_dedupe <树>：同一棵树的凭证里，完全相同的段落只留第一段（union 合并会让两边共有的段落各出现一次）。
_attest_dedupe() {
  local note out
  note=$(git notes --ref="$ATTEST_REF" show "$1" 2>/dev/null) || return 0
  out=$(printf '%s\n' "$note" | awk 'BEGIN { RS = ""; ORS = "\n\n" } !seen[$0]++')
  [ "$out" = "$note" ] && return 0
  _ag notes --ref="$ATTEST_REF" add -f -m "$out" "$1" >/dev/null 2>&1
}

# attest_publish：先把本机缺的凭证补上，再推到远端。返回 0 已发布 | 1 失败 | 3 一份凭证都没有，没有东西可发布。
# 被拒后只有「远端的和本地的分叉了」才合并（别的原因——没权限、没网——合并也没用，直接失败）：
# 取回对方的、按 union 合并（两边的段落都保留）、对两边都改过的树去重、再推一次。整个过程持锁。
attest_publish() {
  local rc
  _attest_lock || { echo "拿不到凭证锁（别的进程占着），稍后重试。" >&2; return 1; }
  _attest_publish_locked; rc=$?
  _attest_unlock
  return $rc
}
_attest_publish_locked() {
  local remote=${ORCH_REMOTE:-origin} ref="refs/notes/$ATTEST_REF" tmp="refs/notes/$ATTEST_REF-sync-$$" before both t r
  # 上次被中断的 publish 可能留下临时 ref：清掉（我们持着锁，没有别的 publish 在用它们）
  for r in $(git for-each-ref --format='%(refname)' "refs/notes/$ATTEST_REF-sync-*" 2>/dev/null); do _ag update-ref -d "$r"; done
  attest_sync
  git rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 3          # 一份凭证都没有（也没有通过记录可补）：没有东西可发布
  _ag push -q -- "$remote" "$ref" 2>/dev/null && return 0
  _ag fetch -q --no-write-fetch-head --refmap= --no-tags -- "$remote" "+$ref:$tmp" 2>/dev/null || return 1
  if git merge-base --is-ancestor "$ref" "$tmp" 2>/dev/null; then       # 本地有的远端都有了：对齐一下就行，没有要发布的
    _ag update-ref "$ref" "$tmp"; _ag update-ref -d "$tmp"; return 0
  fi
  if git merge-base --is-ancestor "$tmp" "$ref" 2>/dev/null; then       # 远端没有任何本地没有的东西，推送却被拒：是别的原因
    _ag update-ref -d "$tmp"; return 1
  fi
  _ag notes --ref="$ATTEST_REF" merge --abort >/dev/null 2>&1 || true     # 清掉上次中断留下的合并现场（没有就什么都不做）
  before=$(git rev-parse "$ref")
  _ag notes --ref="$ATTEST_REF" merge -s union "$tmp" >/dev/null 2>&1 || { _ag update-ref -d "$tmp"; return 1; }
  # 两边都改过的树 = 合并结果既不同于合并前的本地、也不同于远端的那些：只有它们会出现重复段落
  both=$(comm -12 <(git diff --name-only "$before" "$ref" | tr -d '/' | LC_ALL=C sort) <(git diff --name-only "$tmp" "$ref" | tr -d '/' | LC_ALL=C sort))
  for t in $both; do _attest_dedupe "$t"; done
  _ag update-ref -d "$tmp"
  _ag push -q -- "$remote" "$ref" 2>/dev/null
}
