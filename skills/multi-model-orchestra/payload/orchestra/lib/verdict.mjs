#!/usr/bin/env node
// .orchestra/lib/verdict.mjs —— 把审查者交回的原始结论变成可执行的判定。
//
// 文章里的两级制是个「判断」，这里把它变成「检查」：
//   · 阻断项必须说得出怎么发生（触发路径够具体），否则自动降为建议；
//   · 上一轮的阻断项，审查者没明确说「已修好」就继续算阻断（不会因为漏提而溜走）；
//   · 结论不符合 schema（缺字段、类型不对、verdict=block 却没有任何阻断项）→ INVALID，不计轮次、让调用方重跑。
//
// 用法：node verdict.mjs --in <raw> --out-json <f> --out-md <f> --round N --max M
//                         --model X --effort Y [--prev <norm.json>] [--min-path 30] [--base sha] [--head sha]
// stdout 第一行：RESULT=PASS|BLOCK|INVALID；其后是给人看的报告（Markdown）。
import fs from 'node:fs';

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) {
    const nxt = process.argv[i + 1];
    args[a.slice(2)] = nxt !== undefined && !nxt.startsWith('--') ? (i++, nxt) : true;
  }
}

const CLASSES = new Set(['money', 'data_loss', 'authz', 'wrong_message', 'release_incident']);
const CLASS_ZH = { money: '算错钱', data_loss: '丢数据', authz: '越权', wrong_message: '发错消息', release_incident: '发布事故' };
const minPath = Number(args['min-path'] ?? 30);
const round = Number(args.round ?? 1);
const max = Number(args.max ?? 2);

function extractJson(text) {
  const t = text.trim();
  try { return JSON.parse(t); } catch { /* 继续 */ }
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) { try { return JSON.parse(fence[1].trim()); } catch { /* 继续 */ } }
  const start = t.indexOf('{');
  if (start >= 0) {
    let depth = 0, inStr = false, esc = false;
    for (let i = start; i < t.length; i++) {
      const c = t[i];
      if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
      if (c === '"') inStr = true;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) { try { return JSON.parse(t.slice(start, i + 1)); } catch { return null; } }
    }
  }
  return null;
}

const arr = (x) => (Array.isArray(x) ? x : []);
const str = (x) => (typeof x === 'string' ? x : x == null ? '' : String(x));

function finish(norm, md) {
  if (args['out-json']) fs.writeFileSync(args['out-json'], JSON.stringify(norm, null, 2));
  if (args['out-md']) fs.writeFileSync(args['out-md'], md);
  process.stdout.write(`RESULT=${norm.result}\n${md}\n`);
  process.exit(0);
}

let rawText = '';
try { rawText = fs.readFileSync(args.in, 'utf8'); } catch (e) { rawText = ''; }
const raw = extractJson(rawText);

if (!raw || typeof raw !== 'object') {
  finish({ result: 'INVALID', reason: '审查者没有交回可解析的 JSON', round, max },
    `# 审查结论：INVALID\n\n审查者没有交回可解析的 JSON。本次不计轮次，请重跑。\n\n原始输出开头：\n\n\`\`\`\n${rawText.slice(0, 400)}\n\`\`\`\n`);
}
if (raw.verdict !== 'pass' && raw.verdict !== 'block') {
  finish({ result: 'INVALID', reason: 'verdict 缺失或不是 pass/block', round, max },
    '# 审查结论：INVALID\n\nverdict 字段缺失或不是 pass/block。本次不计轮次，请重跑。\n');
}
// 结论必须完整符合 schema（prompts/review.schema.json，additionalProperties:false）：
// 五个顶层字段齐全、类型对，且每个条目的字段齐全、类型对、没有多余字段，line 是整数。
// 缺字段或类型不对一律 INVALID——不能因为「少了 blocking 字段」就被当成空数组放行，
// 也不能因为条目是个空对象 {} 就把 verdict=block 悄悄「降级」成通过。
// （降级只针对【结构完整】但说不出怎么发生 / 类别不在五类内的阻断项。）
{
  const bad = [];
  const isStr = (x) => typeof x === 'string';
  const extra = (where, o, allowed) => {
    const ex = Object.keys(o).filter((k) => !allowed.includes(k));
    if (ex.length) bad.push(`${where} 多出 schema 之外的字段：${ex.join(',')}`);
  };
  extra('顶层', raw, ['verdict', 'summary', 'previous_blockers', 'blocking', 'advisory']);
  if (!isStr(raw.summary)) bad.push('summary 缺失或不是字符串');
  for (const k of ['previous_blockers', 'blocking', 'advisory']) {
    if (!Array.isArray(raw[k])) bad.push(`${k} 缺失或不是数组`);
    else if (!raw[k].every((x) => x && typeof x === 'object' && !Array.isArray(x))) bad.push(`${k} 里有不是对象的元素`);
  }
  if (!bad.length) {
    raw.blocking.forEach((b, k) => {
      extra(`blocking[${k}]`, b, ['id', 'class', 'title', 'file', 'line', 'how_it_happens', 'fix_hint']);
      for (const f of ['id', 'class', 'title', 'file', 'how_it_happens', 'fix_hint']) if (!isStr(b[f])) bad.push(`blocking[${k}].${f} 缺失或不是字符串`);
      if (!Number.isInteger(b.line)) bad.push(`blocking[${k}].line 缺失或不是整数`);
    });
    raw.advisory.forEach((a, k) => {
      extra(`advisory[${k}]`, a, ['title', 'file', 'note']);
      for (const f of ['title', 'file', 'note']) if (!isStr(a[f])) bad.push(`advisory[${k}].${f} 缺失或不是字符串`);
    });
    raw.previous_blockers.forEach((p, k) => {
      extra(`previous_blockers[${k}]`, p, ['id', 'status', 'note']);
      for (const f of ['id', 'status', 'note']) if (!isStr(p[f])) bad.push(`previous_blockers[${k}].${f} 缺失或不是字符串`);
      if (isStr(p.status) && p.status !== 'fixed' && p.status !== 'not_fixed') bad.push(`previous_blockers[${k}].status 必须是 fixed 或 not_fixed`);
    });
  }
  if (bad.length) {
    const shown = bad.slice(0, 6).join('；') + (bad.length > 6 ? `；……共 ${bad.length} 处` : '');
    finish({ result: 'INVALID', reason: `结论不符合 schema：${shown}`, round, max },
      `# 审查结论：INVALID\n\n结论不符合 schema：${shown}。本次不计轮次——让审查者严格按 schema 重出（只输出 JSON），再重试。\n`);
  }
}
const rawBlocking = arr(raw.blocking);
if (raw.verdict === 'block' && rawBlocking.length === 0) {
  finish({ result: 'INVALID', reason: 'verdict=block 但没有任何阻断项', round, max },
    '# 审查结论：INVALID\n\n审查者给了 verdict=block，却没有列出任何阻断项——自相矛盾。本次不计轮次，请重跑。\n');
}

const notes = [];
const advisory = arr(raw.advisory).map((a) => ({ title: str(a.title), file: str(a.file), note: str(a.note) }));
const kept = [];
for (const b0 of rawBlocking) {
  const b = {
    id: str(b0.id) || `B${kept.length + 1}`,
    class: str(b0.class), title: str(b0.title), file: str(b0.file),
    line: Number.isFinite(Number(b0.line)) ? Number(b0.line) : 0,
    how_it_happens: str(b0.how_it_happens).trim(), fix_hint: str(b0.fix_hint),
  };
  let why = '';
  if (!CLASSES.has(b.class)) why = `类别 "${b.class}" 不在五类（money/data_loss/authz/wrong_message/release_incident）内`;
  else if (b.how_it_happens.length < minPath) why = `触发路径不足 ${minPath} 个字符，说不出怎么发生`;
  else if (!b.file) why = '没有给出文件位置';
  if (why) {
    advisory.push({ title: `[自阻断降级] ${b.title}`, file: b.file, note: `${why}。原述：${b.how_it_happens || '（空）'}` });
    notes.push(`阻断项 ${b.id} 被降为建议：${why}`);
  } else kept.push(b);
}

// 上一轮阻断项：审查者没明确说 fixed 就继续算阻断
const prevStatus = arr(raw.previous_blockers).map((p) => ({ id: str(p.id), status: str(p.status), note: str(p.note) }));
let prev = null;
if (args.prev && args.prev !== true) {
  try { prev = JSON.parse(fs.readFileSync(args.prev, 'utf8')); } catch {
    finish({ result: 'INVALID', reason: '无法读取上一轮阻断项记录', round, max },
      '# 审查结论：INVALID\n\n无法读取上一轮的阻断项记录，没法核对遗留阻断项——为防止放过它们，本次不计轮次、不放行。\n');
  }
}
if (prev) {
  for (const p of arr(prev.blocking)) {
    const st = prevStatus.find((x) => x.id === p.id);
    if (!st) notes.push(`上一轮阻断项 ${p.id} 在本轮没有复查结论，按「未修好」处理`);
    if (!(st && st.status === 'fixed') && !kept.some((b) => b.id === p.id)) kept.push({ ...p, carried: true });
  }
}

const result = kept.length > 0 ? 'BLOCK' : 'PASS';
if (raw.verdict === 'pass' && kept.length > 0) notes.push('verdict 写的是 pass，但仍有阻断项——以阻断项为准');

const norm = {
  result, round, max, model: str(args.model), effort: str(args.effort),
  base: str(args.base), head: str(args.head), summary: str(raw.summary),
  blocking: kept, advisory, previous_blockers: prevStatus, notes,
};

const L = [];
L.push(`# 审查结论：${result}（第 ${round}/${max} 轮）`);
L.push(`模型 ${norm.model || '?'} · 推理 ${norm.effort || '?'}${norm.base ? ` · 基点 ${norm.base.slice(0, 10)} → ${norm.head.slice(0, 10)}` : ''}`);
if (norm.summary) L.push('', norm.summary);
if (prevStatus.length) {
  L.push('', '## 上一轮阻断项复查');
  for (const p of prevStatus) L.push(`- ${p.id}：${p.status === 'fixed' ? '已修好' : '未修好'} ${p.note ? '— ' + p.note : ''}`);
}
if (kept.length) {
  L.push('', `## 阻断项（${kept.length}）`);
  for (const b of kept) {
    L.push(`### ${b.id} [${CLASS_ZH[b.class] || b.class}] ${b.title}${b.carried ? '（上一轮遗留）' : ''}`);
    L.push(`- 位置：${b.file}${b.line ? ':' + b.line : ''}`);
    L.push(`- 怎么发生：${b.how_it_happens}`);
    if (b.fix_hint) L.push(`- 修法提示：${b.fix_hint}`);
  }
}
if (advisory.length) {
  L.push('', `## 建议（${advisory.length}，只记录、不阻断）`);
  for (const a of advisory) L.push(`- ${a.file ? '`' + a.file + '` ' : ''}${a.title}${a.note ? ' — ' + a.note : ''}`);
}
if (notes.length) { L.push('', '## 备注'); for (const n of notes) L.push(`- ${n}`); }
finish(norm, L.join('\n') + '\n');
