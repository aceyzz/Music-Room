// handleSummary for every scenario: the per-step verdict that is the answer to
// V.7, plus the full k6 data for loadtest/verify and the write-up.

import { STEPS, HOLD, SLO } from './config.js';

const RESULTS = __ENV.RESULTS_DIR || 'results/latest';

function val(data, key, stat) {
  const m = data.metrics[key];
  return m && m.values && m.values[stat] !== undefined ? m.values[stat] : null;
}

function holdSeconds() {
  const m = /^(\d+)(s|m)$/.exec(HOLD);
  return Number(m[1]) * (m[2] === 'm' ? 60 : 1);
}

function fmt(v, digits = 0) {
  return v === null ? '-' : v.toFixed(digits);
}

export function steps(data) {
  const out = [];
  for (const s of STEPS) {
    const reqs = val(data, `http_reqs{step:${s}}`, 'count');
    if (!reqs) continue; // not reached (aborted run)
    const failed = val(data, `http_req_failed{step:${s}}`, 'rate');
    const read = val(data, `http_req_duration{step:${s},kind:read}`, 'p(95)');
    const write = val(data, `http_req_duration{step:${s},kind:write}`, 'p(95)');
    const ok = (failed === null || failed < SLO.errorRate)
      && (read === null || read < SLO.readP95)
      && (write === null || write < SLO.writeP95);
    out.push({ vus: s, rps: reqs / holdSeconds(), failed, read, write, ok });
  }
  return out;
}

// The answer: the highest step such that it and every step below it held.
export function maxUsers(rows) {
  let best = 0;
  for (const r of rows) {
    if (!r.ok) break;
    best = r.vus;
  }
  return best;
}

export function table(rows) {
  const lines = [
    `SLO: errors < ${SLO.errorRate * 100}%, read p95 < ${SLO.readP95} ms, write p95 < ${SLO.writeP95} ms`,
    '',
    '| VUs | req/s | errors | read p95 (ms) | write p95 (ms) | SLO |',
    '|----:|------:|-------:|--------------:|---------------:|:---:|',
  ];
  for (const r of rows) {
    lines.push(`| ${r.vus} | ${fmt(r.rps, 1)} | ${r.failed === null ? '-' : (r.failed * 100).toFixed(2) + '%'} `
      + `| ${fmt(r.read)} | ${fmt(r.write)} | ${r.ok ? 'held' : 'BROKE'} |`);
  }
  return lines.join('\n');
}

export function handleSummary(data) {
  const rows = steps(data);
  const best = maxUsers(rows);
  const counters = {
    votes_accepted: val(data, 'votes_accepted', 'count') || 0,
    playlist_mutations: val(data, 'playlist_mutations', 'count') || 0,
    conflicts: val(data, 'conflicts', 'count') || 0,
  };
  const text = [
    '',
    table(rows),
    '',
    `Max simultaneous users with the SLO held: ${best || 'none (the first step already broke it)'}`,
    `Votes accepted: ${counters.votes_accepted}, playlist mutations: ${counters.playlist_mutations}, `
      + `expected conflicts: ${counters.conflicts}`,
    '',
  ].join('\n');
  return {
    stdout: text,
    [`${RESULTS}/steps.md`]: text,
    [`${RESULTS}/summary.json`]: JSON.stringify({ maxUsers: best, steps: rows, counters, k6: data }, null, 1),
  };
}
