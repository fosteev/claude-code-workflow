#!/usr/bin/env node
// Лимиты подписки Claude: GET /api/oauth/usage с токеном Claude Code.
// Печатает одну строку JSON: {session, weekly, scoped:[{model,percent}], resets:{…}, sessionResetMs, wakeCron}
// — проценты 0–100; wakeCron — одноразовый cron (локальное время) на сброс 5ч-окна + 3 мин, для CronCreate.
// Токен читается из ~/.claude/.credentials.json или Keychain и никуда не печатается.
// Код выхода: 0 — ок, 2 — не удалось узнать (вызвавший решает сам, обычно «продолжать осторожно»).
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

function token() {
  let raw;
  try {
    raw = readFileSync(join(homedir(), '.claude', '.credentials.json'), 'utf8');
  } catch {
    try {
      raw = execFileSync('/usr/bin/security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w'], {
        encoding: 'utf8',
        timeout: 5000,
      });
    } catch {
      return undefined;
    }
  }
  try {
    return JSON.parse(raw)?.claudeAiOauth?.accessToken;
  } catch {
    return undefined;
  }
}

function fail(reason) {
  console.log(JSON.stringify({ error: reason }));
  process.exit(2);
}

const t = token();
if (!t) fail('нет токена Claude Code');

let res;
try {
  res = await fetch('https://api.anthropic.com/api/oauth/usage', {
    headers: { authorization: `Bearer ${t}`, 'anthropic-beta': 'oauth-2025-04-20' },
    signal: AbortSignal.timeout(10000),
  });
} catch (e) {
  fail(`сеть: ${e.message}`);
}
if (!res.ok) fail(`HTTP ${res.status}`);
const body = await res.json();

const out = { session: null, weekly: null, scoped: [], resets: {} };
const time = (v) => (v ? new Date(v).toLocaleString('ru-RU', { weekday: 'short', hour: '2-digit', minute: '2-digit' }) : null);
for (const l of Array.isArray(body.limits) ? body.limits : []) {
  if (l?.resets_at == null || typeof l.percent !== 'number') continue;
  if (l.kind === 'session') {
    out.session = l.percent;
    out.resets.session = time(l.resets_at);
    const wake = new Date(new Date(l.resets_at).getTime() + 3 * 60_000);
    out.sessionResetMs = wake.getTime() - 3 * 60_000;
    out.wakeCron = `${wake.getMinutes()} ${wake.getHours()} ${wake.getDate()} ${wake.getMonth() + 1} *`;
  } else if (l.kind === 'weekly_all') {
    out.weekly = l.percent;
    out.resets.weekly = time(l.resets_at);
  } else if (l.kind === 'weekly_scoped') {
    out.scoped.push({ model: l.scope?.model?.display_name ?? l.scope?.model?.id ?? '?', percent: l.percent });
  }
}
console.log(JSON.stringify(out));
