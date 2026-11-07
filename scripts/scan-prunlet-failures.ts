import { readdir } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { homedir } from 'node:os';

// 入力ログは実行せず、tool出力に含まれる削除DTOだけを集計する。
const args = process.argv.slice(2);
const option = (name: string, fallback: string) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const days = Number(option('--days', '3'));
if (!Number.isFinite(days) || days <= 0) throw new Error('--days must be positive');
const root = option('--root', join(homedir(), '.codex', 'sessions'));
const end = new Date(option('--until', new Date().toISOString()));
if (!Number.isFinite(end.getTime())) throw new Error('Invalid --until');
const start = new Date(end.getTime() - days * 86400000);
const counts: Record<string, number> = {};
const hits: object[] = [];
const relatedFailures: object[] = [];
let files = 0, events = 0, malformed = 0;
let nonDtoFailedCalls = 0;
let unattributedDtoItems = 0;
const signatures = new Set<string>();
const category = (error: string) => /0x80270021|ACCESS_DENIED|access.*denied|アクセス.*拒否/i.test(error) ? 'access_denied'
  : /sharing violation|共有違反|error.*32\b/i.test(error) ? 'sharing_violation'
  : /policy|unsupported|reparse|link-like|protected|reserved|not allowed/i.test(error) ? 'safety_refusal'
  : /confirm|uncertain|ambiguous|不明/i.test(error) ? 'unconfirmed' : 'other';

function failedOutput(value: unknown, depth = 0): boolean {
  if (depth > 12 || value == null) return false;
  if (typeof value === 'object') {
    const v = value as any;
    if (v.isError === true || [v.exit_code, v.exitCode].some(code => typeof code === 'number' && code !== 0)) return true;
    return Object.values(v).some(child => failedOutput(child, depth + 1));
  }
  if (typeof value !== 'string') return false;
  try { return failedOutput(JSON.parse(value), depth + 1); } catch {}
  return /blocked by|isError"?\s*:\s*true/i.test(value)
    || [...value.matchAll(/(?:exit_code|exitCode)"?\s*:\s*(-?\d+)|exited with code (-?\d+)/gi)]
      .some(match => Number(match[1] ?? match[2]) !== 0);
}

function results(value: unknown, emit: (v: any) => void, depth = 0) {
  if (depth > 12 || value == null) return;
  if (typeof value === 'object') {
    const v = value as any;
    if (typeof v.dryRun === 'boolean' && Array.isArray(v.items)) emit(v);
    else for (const child of Object.values(v)) results(child, emit, depth + 1);
  } else if (typeof value === 'string') {
    try { results(JSON.parse(value), emit, depth + 1); return; } catch {}
    // execの見出しに続くJSONも読む。ソースコードや会話の文字列は対象外。
    for (const line of value.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try { results(JSON.parse(trimmed), emit, depth + 1); } catch {}
      }
    }
    for (const match of value.matchAll(/\{\s*"/g)) {
      let level = 0, quoted = false, escaped = false;
      for (let i = match.index!; i < value.length; i++) {
        const c = value[i];
        if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
        else if (c === '"') quoted = true;
        else if (c === '{') level++;
        else if (c === '}' && --level === 0) {
          try { results(JSON.parse(value.slice(match.index, i + 1)), emit, depth + 1); } catch {}
          break;
        }
      }
    }
  }
}
async function walk(dir: string): Promise<void> {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) { await walk(path); continue; }
    if (!entry.isFile() || !entry.name.endsWith('.jsonl')) continue;
    // 再開された古いsessionも対象。mtimeや保存ディレクトリの日付では除外しない。
    files++;
    const calls = new Map<string, { name: string; args: string }>();
    const input = createInterface({ input: createReadStream(path), crlfDelay: Infinity });
    for await (const line of input) {
      let record: any;
      try { record = JSON.parse(line); } catch { malformed++; continue; }
      const p = record.payload;
      if (record.type !== 'response_item' || !p) continue;
      if (p.type === 'function_call' || p.type === 'custom_tool_call') {
        calls.set(p.call_id, { name: p.name ?? '', args: p.arguments ?? p.input ?? '' });
        continue;
      }
      if (p.type !== 'function_call_output' && p.type !== 'custom_tool_call_output') continue;
      const time = Date.parse(record.timestamp);
      if (!Number.isFinite(time) || time < start.getTime() || time > end.getTime()) continue;
      events++;
      const call = calls.get(p.call_id);
      const seen = new Set<string>();
      const prunletContext = !!call && /prunlet/i.test(call.name + call.args);
      results(p.output, dto => {
        if (dto.dryRun) return;
        for (const item of dto.items) {
          if (!item || !['failed', 'ambiguous'].includes(item.status) || typeof item.path !== 'string') continue;
          const error = String(item.error ?? '');
          const key = JSON.stringify([item.path, item.status, error]);
          if (seen.has(key)) continue;
          seen.add(key);
          if (!prunletContext) { unattributedDtoItems++; continue; }
          signatures.add(key);
          const reason = category(error);
          counts[reason] = (counts[reason] ?? 0) + 1;
          const fixture = /validation|fixture|verify|recordless|smoke|native-startup|race-v|[\\/]e2e[\\/]|\\run-\d+\\/i.test(item.path);
          hits.push({ time: record.timestamp, log: path, callId: p.call_id, tool: call?.name,
            context: /Get-Content|ReadAllText|readFile|scan-prunlet/i.test(call?.args ?? '') ? 'evidence_read_candidate' : 'execution_or_nested',
            path: item.path, status: item.status, reason, fixture, error });
        }
      });
      if (!seen.size && call && /prunlet/i.test(call.name + call.args)
        && /delete_files|delete_registry|\bregistry-delete\b|\bdelete\b/i.test(call.name + call.args)
        && failedOutput(p.output)) {
          nonDtoFailedCalls++;
          relatedFailures.push({time:record.timestamp,log:path,callId:p.call_id,tool:call.name});
        }
    }
  }
}
await walk(root);
console.log(JSON.stringify({ start: start.toISOString(), end: end.toISOString(), files, outputEvents: events,
  malformedLines: malformed, failureObservations: hits.length, distinctPathStatusErrors: signatures.size,
  byReason: counts, nonDtoFailedCalls, unattributedDtoItems, limitation: 'One path/status/full-error signature per outer output event with Prunlet call context. The context match is lexical; composite exec outputs cannot always be attributed to a nested call. Unattributed DTOs are separate. Nested repeated attempts cannot always be distinguished from mirrored results. DTO observations are not unique operations or proven bugs. Re-read evidence and fixture labels are heuristics. Non-DTO failures are related call candidates, not additional failed items. Truncated or unrecorded outputs cannot be counted.',
  ...(args.includes('--details') ? { hits, relatedFailures } : {}) }, null, 2));
