#!/usr/bin/env node
// .orchestra/hooks/guard.mjs —— Claude Code PreToolUse 钩子（matcher: Bash）。
// 把文章里几条「不许」变成硬检查，而不是靠总指挥自觉：
//   R1 不直接调 codex exec/review/resume/fork   —— 默认权限不受控；干活走 codex-worker，审查走 codex-review
//   R2 不直接调 agy 的对话/打印模式              —— 会绕过「只读 + 固定模型 + 回答规范」；走 agy-ask
//   R3 codex / agy 的 --dangerously-* 参数       —— 跳过沙箱/审批
//   R4 codex-review approve|again               —— 这是【用户的决定】：弹确认，不静默放行
//   R5 绕过审查门：git push --no-verify、ORCH_GATE=off —— 只有用户本人可以
// 输入：stdin 为 Claude Code 的钩子 JSON。输出：拦截=退出码 2+stderr；需确认=退出 0+JSON(ask)；放行=退出 0。
//
// 实现：一个小型 shell 解析器，只检查「真正在命令位置」的调用——
//   · 引号里的字样、加引号的 heredoc 正文只是数据，不会误伤；
//   · $( )、反引号、<( )、未加引号的 heredoc 正文里的替换会真的执行，所以会展开检查；
//   · bash -c / eval 的字符串递归检查；
//   · 跳过保留字（if/then/do/!/{…）、带选项的包装器（env/sudo/timeout/nohup/command/xargs…）、重定向、前缀赋值；
//   · git 的全局选项（-C、-c、--no-pager…）先剥掉再认子命令。
// 这是字符串分析：挡的是「顺手/误操作」，不防有意的深度绕过（npx codex exec、脚本里间接调用）。
// 守卫自己出错时降级为「请用户确认」，不会静默放行。
import fs from 'node:fs';

const base = (t) => String(t).replace(/^.*[\\/]/, '').replace(/\.(exe|cmd|ps1|bat)$/i, '').toLowerCase();
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;

// 找与 s[open]==='(' 配对的 ')'，处理嵌套、引号、转义；找不到返回 s.length
function matchParen(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    const c = s[i];
    if (c === '\\') { i++; continue; }
    if (c === "'") { const j = s.indexOf("'", i + 1); if (j === -1) return s.length; i = j; continue; }
    if (c === '"') { i++; while (i < s.length && s[i] !== '"') { if (s[i] === '\\') i++; i++; } continue; }
    if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return i;
  }
  return s.length;
}

// 在一段「会展开的文本」里找 $( ) 与反引号，把里面的命令文本交给 emit
function scanSubstitutions(text, emit) {
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '\\') { i++; continue; }
    if (c === '$' && text[i + 1] === '(' && text[i + 2] !== '(') { const e = matchParen(text, i + 1); emit(text.slice(i + 2, e)); i = e; continue; }
    if (c === '`') { const e = text.indexOf('`', i + 1); const end = e === -1 ? text.length : e; emit(text.slice(i + 1, end)); i = end; continue; }
  }
}

// 把 shell 文本切成「简单命令」：每个 = { words: string[] }（已去引号）。命令替换里的命令也并入列表。
// 重定向（> >> >| >& < <& <> <<< &> 以及前面的 fd 数字）连同它的【目标词】一起丢掉：
// 否则「--no-verify>/dev/null」会被当成一个词，守卫就认不出 --no-verify 了。
// 做法：遇到重定向操作符就立起 skipNext，紧接着完成的那个词就是它的目标，丢掉并放下标志。
// （不能用「哨兵词＋丢下一个元素」：连续重定向 `2>&1>/dev/null cmd` 里，前一个的目标 `1` 会被后一个当成 fd 前缀，
//   目标 `/dev/null` 就漏到了命令位置。差分测试 tests/guard-diff.mjs 抓到过。）
function parseShell(src, depth = 0) {
  const cmds = [];
  if (depth > 4) return cmds;
  const n = src.length;
  let i = 0, words = [], cur = '', has = false, skipNext = false;
  const heredocs = [];
  const flushWord = () => {
    if (!has) return;
    if (skipNext) skipNext = false; else words.push(cur);
    cur = ''; has = false;
  };
  const flushCmd = () => { flushWord(); if (words.length) cmds.push({ words }); words = []; skipNext = false; };
  const sub = (inner) => { for (const c of parseShell(inner, depth + 1)) cmds.push(c); };

  while (i < n) {
    const c = src[i];
    if (c === '\\') {                                           // 反斜杠：续行整个吃掉；否则转义下一字符
      if (src[i + 1] === '\n') { i += 2; continue; }
      if (i + 1 < n) { cur += src[i + 1]; has = true; i += 2; continue; }
      i++; continue;
    }
    if (c === "'") {                                            // 单引号：纯字面
      const j = src.indexOf("'", i + 1); const e = j === -1 ? n : j;
      cur += src.slice(i + 1, e); has = true; i = e + 1; continue;
    }
    if (c === '"') {                                            // 双引号：$( ) 与反引号仍然执行
      i++; has = true;
      while (i < n && src[i] !== '"') {
        const d = src[i];
        if (d === '\\' && i + 1 < n) {
          if (src[i + 1] === '\n') { i += 2; continue; }
          cur += '"\\$`'.includes(src[i + 1]) ? src[i + 1] : '\\' + src[i + 1]; i += 2; continue;
        }
        if (d === '$' && src[i + 1] === '(' && src[i + 2] !== '(') { const e = matchParen(src, i + 1); sub(src.slice(i + 2, e)); cur += '\u0000'; i = e + 1; continue; }
        if (d === '`') { const e = src.indexOf('`', i + 1); const end = e === -1 ? n : e; sub(src.slice(i + 1, end)); cur += '\u0000'; i = end + 1; continue; }
        cur += d; i++;
      }
      i++; continue;
    }
    if (c === '$' && src[i + 1] === "'") {                       // $'…'
      let j = i + 2, buf = '';
      while (j < n && src[j] !== "'") { if (src[j] === '\\' && j + 1 < n) { buf += src[j + 1]; j += 2; } else buf += src[j++]; }
      cur += buf; has = true; i = j + 1; continue;
    }
    if (c === '$' && src[i + 1] === '(') {                       // $( ) 命令替换；$(( )) 算术直接跳过
      const e = matchParen(src, i + 1);
      if (src[i + 2] !== '(') sub(src.slice(i + 2, e));
      cur += '\u0000'; has = true; i = e + 1; continue;
    }
    if (c === '`') { const e = src.indexOf('`', i + 1); const end = e === -1 ? n : e; sub(src.slice(i + 1, end)); cur += '\u0000'; has = true; i = end + 1; continue; }
    if ((c === '<' || c === '>') && src[i + 1] === '(') {         // 进程替换 <( ) >( )
      const e = matchParen(src, i + 1); sub(src.slice(i + 2, e)); cur += '\u0000'; has = true; i = e + 1; continue;
    }
    if (c === '<' && src[i + 1] === '<' && src[i + 2] !== '<') {  // heredoc（<<< 是 here-string，不算）
      let j = i + 2, strip = false;
      if (src[j] === '-') { strip = true; j++; }
      while (src[j] === ' ' || src[j] === '\t') j++;
      let delim = '', quoted = false;
      while (j < n && !/[\s;&|()<>]/.test(src[j])) {
        if (src[j] === "'" || src[j] === '"') { quoted = true; const q = src[j]; const e = src.indexOf(q, j + 1); delim += src.slice(j + 1, e === -1 ? n : e); j = (e === -1 ? n : e) + 1; continue; }
        if (src[j] === '\\') { quoted = true; delim += src[j + 1] ?? ''; j += 2; continue; }
        delim += src[j++];
      }
      heredocs.push({ delim, quoted, strip });
      i = j; continue;
    }
    if (c === '>' || c === '<' || (c === '&' && src[i + 1] === '>')) {   // 重定向操作符（<(  >(  <<  已在前面处理）
      // 前面攒着的纯数字词：若还没在等目标，它是 fd 前缀（2> 里的 2），直接丢；否则它就是上一个重定向的目标，由 flushWord 丢
      if (has && !skipNext && /^[0-9]+$/.test(cur)) { cur = ''; has = false; } else flushWord();
      let j = i;
      if (src[j] === '&') j++;
      while (src[j] === '>' || src[j] === '<') j++;
      if (src[j] === '&' || src[j] === '|') j++;
      skipNext = true; i = j; continue;
    }
    if (c === ' ' || c === '\t' || c === '\r') { flushWord(); i++; continue; }
    if (c === '\n') {                                            // 换行：结束命令；之后是 heredoc 正文
      flushCmd(); i++;
      while (heredocs.length) {
        const h = heredocs.shift(); let body = '';
        while (i < n) {
          let e = src.indexOf('\n', i); if (e === -1) e = n;
          const line = src.slice(i, e).replace(/\r$/, ''); i = Math.min(e + 1, n);
          if ((h.strip ? line.replace(/^\t+/, '') : line) === h.delim) break;
          body += line + '\n';
        }
        if (!h.quoted) scanSubstitutions(body, sub);              // 未加引号的 heredoc：里面的替换会执行
      }
      continue;
    }
    if (c === '#' && !has) { while (i < n && src[i] !== '\n') i++; continue; }   // 注释（词首的 #）
    if (c === ';' || c === '|' || c === '&' || c === '(' || c === ')') { flushCmd(); i++; continue; }
    cur += c; has = true; i++;
  }
  flushCmd();
  return cmds;
}

const RESERVED = new Set(['if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until', 'for', 'case', 'esac', 'in', 'select', 'function', '!', '{', '}']);
// 包装器：后面跟着真正的命令。flagsWithValue = 带取值的选项；positional = 后面要再跳过几个位置参数
const WRAP = {
  env: { flagsWithValue: ['-u', '--unset', '-C', '--chdir', '-S', '--split-string'] },
  command: {}, builtin: {}, exec: {}, nohup: {}, setsid: {}, time: {}, doas: {},
  stdbuf: { flagsWithValue: ['-i', '-o', '-e'] },
  sudo: { flagsWithValue: ['-u', '-g', '-h', '-p', '-C', '-U', '-T', '-r', '-t', '-D', '-R'] },
  nice: { flagsWithValue: ['-n', '--adjustment'] },
  ionice: { flagsWithValue: ['-c', '-n', '-p'] },
  timeout: { flagsWithValue: ['-s', '--signal', '-k', '--kill-after'], positional: 1 },
  xargs: { flagsWithValue: ['-n', '-I', '-P', '-L', '-d', '-E', '-s', '-a', '--max-args', '--replace', '--max-procs', '--delimiter', '--arg-file'] },
};

// 找到真正的命令词：跳过保留字、前缀赋值、包装器及其选项。返回 { i, assigns, query }。
// query=true：形如 `command -v codex exec`，只是查询命令名，不是执行。
function commandStart(words) {
  let i = 0, query = false; const assigns = [];
  for (;;) {
    if (i >= words.length) return { i, assigns, query };
    const w = words[i];
    if (RESERVED.has(w)) { i++; continue; }
    if (ASSIGN.test(w)) { assigns.push(w); i++; continue; }
    const b = base(w); const spec = WRAP[b];
    if (!spec) return { i, assigns, query };
    i++;
    while (i < words.length) {
      const x = words[i];
      if (x === '--') { i++; break; }
      if (b === 'env' && ASSIGN.test(x)) { assigns.push(x); i++; continue; }
      if (b === 'command' && (x === '-v' || x === '-V')) query = true;
      if (x.startsWith('-') && x.length > 1) { i++; if (spec.flagsWithValue && spec.flagsWithValue.includes(x)) i++; continue; }
      break;
    }
    if (spec.positional) i += spec.positional;
  }
}

const CODEX_SUBS = new Set(['exec', 'e', 'review', 'resume', 'fork']);
const AGY_RUN_FLAGS = new Set(['-p', '--print', '--prompt', '-i', '--prompt-interactive', '-c', '--continue', '-r', '--resume', '--conversation']);
const GIT_OPT_WITH_VALUE = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix', '--config-env']);
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh']);
const GATE_OFF = /^ORCH_GATE=(off|0|false|no)$/i;

function inspect(cmd, out, depth) {
  const { i, assigns, query } = commandStart(cmd.words);
  for (const a of assigns) if (GATE_OFF.test(a)) out.deny.push('R5 禁止用 ORCH_GATE=off 关闭审查门——只有用户本人可以这样做。');
  if (query || i >= cmd.words.length) return;
  const name = base(cmd.words[i]); const rest = cmd.words.slice(i + 1);

  if (name === 'codex') {
    const sub = rest.find((x) => CODEX_SUBS.has(x));
    if (sub) out.deny.push(`R1 禁止直接调用 codex ${sub}：裸调的权限不受控（文章：codex exec 默认完全访问）。\n   干活：bash .orchestra/bin/codex-worker <工作树> "<任务>"\n   审查：bash .orchestra/bin/codex-review run`);
    const d = rest.find((x) => /^--dangerously-/.test(x));
    if (d) out.deny.push(`R3 禁止 ${d}：它会跳过沙箱/审批。`);
  } else if (name === 'agy') {
    if (rest.some((x) => AGY_RUN_FLAGS.has(x))) out.deny.push('R2 禁止直接调用 agy 的对话/打印模式：会绕过「只读 + 固定模型 + 回答规范」。\n   用：bash .orchestra/bin/agy-ask <目录> "<任务>"');
    const d = rest.find((x) => /^--dangerously-/.test(x));
    if (d) out.deny.push(`R3 禁止 ${d}：它会跳过沙箱/审批。`);
  } else if (name === 'git') {
    let k = 0;
    while (k < rest.length) { if (GIT_OPT_WITH_VALUE.has(rest[k])) { k += 2; continue; } if (rest[k].startsWith('-')) { k++; continue; } break; }
    if (rest[k] === 'push' && rest.slice(k + 1).includes('--no-verify')) out.deny.push('R5 禁止 git push --no-verify：它绕过审查门。只有用户本人可以这样做。');
  } else if (SHELLS.has(name)) {
    const j = rest.findIndex((x) => /^-[A-Za-z]*c[A-Za-z]*$/.test(x));
    if (j >= 0 && rest[j + 1] !== undefined) analyze(rest[j + 1], out, depth + 1);
  } else if (name === 'eval') {
    analyze(rest.join(' '), out, depth + 1);
  } else if (name === 'export' || name === 'declare' || name === 'typeset' || name === 'readonly') {
    for (const a of rest) if (GATE_OFF.test(a)) out.deny.push('R5 禁止用 ORCH_GATE=off 关闭审查门——只有用户本人可以这样做。');
  } else if (name === 'find' || name === 'fd') {
    for (let j = 0; j < rest.length; j++) {
      if (['-exec', '-execdir', '-ok', '-okdir', '-x', '--exec', '-X', '--exec-batch'].includes(rest[j])) {
        let e = j + 1; const w = [];
        while (e < rest.length && rest[e] !== ';' && rest[e] !== '+') w.push(rest[e++]);
        if (w.length) inspect({ words: w }, out, depth + 1);
      }
    }
  }
  // R4：codex-review approve|again（经 bash 调用或直接调用，所以按位置找）
  const k = cmd.words.findIndex((x) => base(x) === 'codex-review');
  if (k >= 0) {
    const sub = cmd.words.slice(k + 1).find((x) => x === 'approve' || x === 'again');
    if (sub) out.ask.push(`codex-review ${sub} 是【用户的决定】（放行/再审）。只有用户在对话里明确答复之后才能执行，--by 里要写用户原话。`);
  }
}

function analyze(text, out, depth = 0) {
  if (depth > 4) return;
  for (const cmd of parseShell(text, depth)) inspect(cmd, out, depth);
}

function main() {
  let ev;
  try { ev = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return 0; }
  if (!ev || ev.tool_name !== 'Bash') return 0;
  const out = { deny: [], ask: [] };
  try {
    analyze(String(ev.tool_input?.command ?? ''), out);
  } catch (e) {
    out.ask.push(`守卫分析这条命令时出错（${e?.message ?? e}），保守起见请用户确认。`);
  }
  if (out.deny.length) {
    process.stderr.write(`[orchestra 守卫] 已拦截：\n${[...new Set(out.deny)].join('\n')}\n`);
    return 2;
  }
  if (out.ask.length) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'ask', permissionDecisionReason: `[orchestra 守卫] ${[...new Set(out.ask)].join(' ')}` },
    }));
  }
  return 0;
}

process.exit(main());
