#!/usr/bin/env bash
# .orchestra/lib/common.sh —— 被各脚本 source，不要直接执行。
#
# 刻意的约束：
#   · 不调用 date / 时区 / 定位 / 网络信息类命令；运行记录目录用「pid+随机数」命名，不带时间戳。
#   · 第三方 CLI 的输出流式经 scrub_log 擦掉时间戳再落盘（run_scrubbed），原始输出不在磁盘上停留。
#   · 外发提示词先脱敏（redact）：尽力而为，不是保证。

[ -n "${_ORCH_COMMON_LOADED:-}" ] && return 0
_ORCH_COMMON_LOADED=1

# Git Bash 会把「长得像路径」的参数改写后再交给原生程序；统一关掉，路径一律用 to_native 显式转换，
# 或者先 cd 进去再调（原生 git.exe 看不懂 /d/xxx 这类 POSIX 路径，所以别写 git -C <POSIX 路径>）。
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1

ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_HOME="$(cd "$ORCH_LIB_DIR/.." && pwd)"

# shellcheck source=/dev/null
[ -f "$ORCH_HOME/orchestra.conf" ] && . "$ORCH_HOME/orchestra.conf"

ORCH_RUNS_DIR="${ORCH_RUNS_DIR:-$ORCH_HOME/runs}"
# 相对路径在脚本里 cd 之后会失效，这里钉成绝对路径（不创建目录）
case "$ORCH_RUNS_DIR" in /*|[A-Za-z]:*) ;; *) ORCH_RUNS_DIR="$PWD/$ORCH_RUNS_DIR" ;; esac

die()  { printf '错误：%s\n' "$*" >&2; exit "${DIE_CODE:-2}"; }
warn() { printf '提示：%s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { DIE_CODE=4; die "找不到命令：$1。${2:-}"; }
}

# Git Bash 路径 → Windows 混合路径（D:/x/y）；非 Windows 原样返回
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s' "$1"; fi
}

# ── 脱敏 ──────────────────────────────────────────────────────────────
# 核心档：高置信度的密钥格式、私钥块、本机用户目录。代码、diff、任务书用这档，不会改坏代码。
_REDACT_CORE=$(cat <<'EOF'
/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
<private-key-removed>
s#[A-Za-z]:[\\/]+Users[\\/]+[^\\/ "'<>|)]+#<HOME>#g
s#/[a-z]/Users/[^/ "'<>|)]+#<HOME>#g
s#/(Users|home)/[^/ "'<>|)]+#<HOME>#g
s#sk-[A-Za-z0-9_-]{16,}#<secret>#g
s#gh[pousr]_[A-Za-z0-9]{20,}#<secret>#g
s#github_pat_[A-Za-z0-9_]{20,}#<secret>#g
s#AKIA[0-9A-Z]{16}#<secret>#g
s#xox[baprs]-[A-Za-z0-9-]{10,}#<secret>#g
s#AIza[0-9A-Za-z_-]{30,}#<secret>#g
s#eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}#<secret>#g
s#([Bb]earer )[A-Za-z0-9._~+/=-]{16,}#\1<secret>#g
EOF
)
# 个人信息档：邮箱、IPv4、「名字=值」形式的密钥（名字可带引号如 JSON 字段；值可带引号，引号值可含空格和转义引号）。
# 只用于给 Gemini 的 brief（自然语言），不用于代码。IPv6 没覆盖（`a::b` 这类标识符会被误伤）。
_REDACT_PERSONAL=$(cat <<'EOF'
s#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<email>#g
s#((^|[^A-Za-z0-9])["']?(api[_-]?key|(access|refresh|auth|bearer|session|id)[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd|authorization|secret|token)["']?[[:space:]]*[:=][[:space:]]*)"([^"\\]|\\.)*"#\1"<secret>"#Ig
s#((^|[^A-Za-z0-9])["']?(api[_-]?key|(access|refresh|auth|bearer|session|id)[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd|authorization|secret|token)["']?[[:space:]]*[:=][[:space:]]*)'([^'\\]|\\.)*'#\1'<secret>'#Ig
s#((^|[^A-Za-z0-9])["']?(api[_-]?key|(access|refresh|auth|bearer|session|id)[_-]?token|secret[_-]?key|client[_-]?secret|password|passwd|authorization|secret|token)["']?[[:space:]]*[:=][[:space:]]*)[^[:space:],;"']+#\1<secret>#Ig
s#127\.0\.0\.1#@@LOOP@@#g
s#0\.0\.0\.0#@@ANY@@#g
s#\b([0-9]{1,3}\.){3}[0-9]{1,3}\b#<ip>#g
s#@@LOOP@@#127.0.0.1#g
s#@@ANY@@#0.0.0.0#g
EOF
)

# redact [code]：stdin → stdout。不带参数 = 两档都用（自然语言 brief）；code = 只用核心档（代码/diff/任务书）。
redact() {
  if [ "${1:-}" = "code" ]; then
    sed -E -f <(printf '%s\n' "$_REDACT_CORE")
  else
    sed -E -f <(printf '%s\n%s\n' "$_REDACT_CORE" "$_REDACT_PERSONAL")
  fi
}

# 第三方 CLI 的日志/事件流里的时间一律擦掉：ISO 日期时间、纯日期、只有时分秒的日志前缀、
# JSON 里 ts/timestamp/created_at 这类字段的 epoch 数字。只用于日志与事件流，不用于模型的回答和代码。
scrub_log() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<ts>/g' \
    -e 's/"(ts|time|timestamp|created|created_at|createdAt|updated_at|updatedAt|started_at|startedAt|finished_at|finishedAt|completed_at|completedAt|date|datetime|time_ms|ts_ms)"[[:space:]]*:[[:space:]]*[0-9]{9,}/"\1":"<ts>"/g' \
    -e 's/\b[0-2][0-9]:[0-5][0-9]:[0-5][0-9]([.,][0-9]+)?\b/<time>/g' \
    -e 's/\b(19|20)[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\b/<date>/g'
}

# run_scrubbed <stdin文件> <stdout文件> <stderr文件> <是否擦stdout:1|0> -- <命令…>
# 命令的 stderr（以及可选的 stdout）流式经 scrub_log 再落盘：原始输出（含时间戳）从不在磁盘上停留，
# 中途被杀也没有残留。返回命令自身的退出码。命令可以是 shell 函数。
# 函数体是子 shell：fd 8/9 只在里面用，不会占用或关掉调用方自己的 fd。
run_scrubbed() (
  in=$1 out=$2 err=$3 sc=$4
  shift 5
  exec 8> >(scrub_log >"$err"); pe=$!
  if [ "$sc" = 1 ]; then exec 9> >(scrub_log >"$out"); po=$!; else exec 9>"$out"; po=""; fi
  "$@" <"$in" >&9 2>&8; rc=$?
  exec 8>&- 9>&-
  wait $pe $po 2>/dev/null
  exit $rc
)

# ── 运行记录 ──────────────────────────────────────────────────────────
mk_run_dir() {
  local d="$ORCH_RUNS_DIR/$1-$$-$RANDOM"
  mkdir -p "$d" || { DIE_CODE=4; die "无法创建运行目录 $d"; }
  printf '%s' "$d"
}

# ── 只读校验：整个仓库（或非 git 目录）的指纹 ─────────────────────────────
# 顾问跑完后指纹必须不变，否则说明它动了文件。这是「检测」，不是「隔离」：
#   · 已跟踪文件的改动 / 未跟踪文件：比内容哈希
#   · HEAD、当前分支、所有 ref（分支/标签/stash）：顾问改了文件又【提交】了，工作区干净收尾，
#     status 和相对 HEAD 的 diff 都是空的——只有 ref 变了才看得出来
#   · 被 .gitignore 忽略的文件（.env 之类）：≤1MB 的比内容哈希（改成同样大小、再把修改时间恢复也逃不掉），
#     更大的只比 路径+大小+修改时间；并排除几类常年自己在变的目录（node_modules、构建产物、缓存、*.log），
#     要调整就设 ORCH_FP_EXCLUDE（扩展正则）。
tree_fingerprint() {
  local d=$1
  (
    cd "$d" || exit 1
    ex="${ORCH_FP_EXCLUDE:-(^|/)(node_modules|\.venv|venv|__pycache__|\.next|\.nuxt|\.cache|dist|build|target|coverage|\.turbo|\.pytest_cache|\.mypy_cache|\.gradle)/|\.log$}"
    if top=$(git rev-parse --show-toplevel 2>/dev/null); then
      cd "$top" || exit 1
      ign() { git ls-files -o -i --exclude-standard -z -- . ':!.orchestra/runs' 2>/dev/null | grep -zvE "$ex" | sed -z 's#^#./#'; }
      {
        git rev-parse HEAD 2>/dev/null
        git symbolic-ref -q HEAD 2>/dev/null
        git for-each-ref --format='%(refname) %(objectname)' 2>/dev/null
        git status --porcelain=v1 -uall -- . ':!.orchestra/runs' 2>/dev/null
        git diff HEAD --no-ext-diff -- . ':!.orchestra/runs' 2>/dev/null
        git ls-files -o --exclude-standard -z -- . ':!.orchestra/runs' 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null
        # 注意：xargs 把文件名追加在命令末尾，而 find 要求路径在表达式前面——所以用 sh -c 把 "$@" 放到最前
        ign | xargs -0 -r sh -c 'find "$@" -maxdepth 0 -type f -size -1025k -print0' _ 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null
        ign | xargs -0 -r sh -c 'find "$@" -maxdepth 0 -type f -size +1024k -print0' _ 2>/dev/null | xargs -0 -r stat -c '%n %s %Y' 2>/dev/null
      } | sha256sum | cut -d' ' -f1
    else
      {
        find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.orchestra/runs/*' -size -1025k -print0 2>/dev/null \
          | LC_ALL=C sort -z | xargs -0 -r sha256sum 2>/dev/null
        find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.orchestra/runs/*' -size +1024k \
          -printf '%p\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort
      } | sha256sum | cut -d' ' -f1
    fi
  )
}

# 可选的外部通知：把摘要从 stdin 喂给 ORCH_NOTIFY_CMD。失败不影响主流程。
notify_human() {
  [ -n "${ORCH_NOTIFY_CMD:-}" ] || return 0
  printf '%s\n' "$1" | bash -c "$ORCH_NOTIFY_CMD" >/dev/null 2>&1 || warn "ORCH_NOTIFY_CMD 执行失败（已忽略）"
}
