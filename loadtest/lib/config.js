// Shared by every scenario: the fixtures, who each virtual user is, and the
// stepped ramp that turns a run into "how many simultaneous users".
//
// Method (docs/load-testing.md): VUs climb in steps (STEPS), each held for
// HOLD after a RAMP. Every request is tagged with the step it ran in, and each
// step gets its own thresholds -- so the summary says, per step, whether the
// SLO held. The answer is the last step that held.

import { SharedArray } from 'k6/data';
import exec from 'k6/execution';

export const BASE_URL = __ENV.BASE_URL || 'http://backend:8081';

// The same think time as the app: the live event page and the playlist page
// both poll every 5 s (frontend/app/lib/features/*/stores/*_store.dart).
export const POLL_SECONDS = Number(__ENV.POLL_SECONDS || 5);

// SLO. Reads are what a phone does every 5 s; writes are a tap.
export const SLO = {
  readP95: Number(__ENV.SLO_READ_P95 || 300),
  writeP95: Number(__ENV.SLO_WRITE_P95 || 500),
  errorRate: Number(__ENV.SLO_ERROR_RATE || 0.01),
};

// One copy for all VUs (SharedArray), not one per VU: at 1,000 VUs a
// per-VU copy of the fixtures alone would be a quarter of a gigabyte.
const fixtures = () => JSON.parse(open('../fixtures.json'));
export const users = new SharedArray('users', () => fixtures().users);
export const events = new SharedArray('events', () => fixtures().events);
export const playlists = new SharedArray('playlists', () => fixtures().playlists);
export const circles = new SharedArray('circles', () => fixtures().circles);
export const songs = new SharedArray('songs', () => fixtures().songs);
export const demoEvent = new SharedArray('demo', () => [fixtures().demoEvent || ''])[0];

// VU n is user n-1. Past the population two VUs would share an account (and
// its votes), which `make loadtest` prevents by seeding at least as many users
// as the top step.
export function me() {
  return users[(exec.vu.idInTest - 1) % users.length];
}
export function meIndex() {
  return (exec.vu.idInTest - 1) % users.length;
}

export function pickOne(list) {
  return list[Math.floor(Math.random() * list.length)];
}

// --- the stepped ramp ---------------------------------------------------------

export const STEPS = (__ENV.STEPS || '25,50,100,200,400,800').split(',').map(Number);
export const RAMP = __ENV.RAMP || '30s';
export const HOLD = __ENV.HOLD || '2m';

function seconds(d) {
  const m = /^(\d+)(s|m)$/.exec(d);
  if (!m) throw new Error(`duration ${d}: use <n>s or <n>m`);
  return Number(m[1]) * (m[2] === 'm' ? 60 : 1);
}

// k6 stages for a scenario holding `share` of the VUs (the mixed scenario
// splits each step between three populations).
export function stages(share = 1) {
  const out = [];
  for (const s of STEPS) {
    const target = Math.max(1, Math.round(s * share));
    out.push({ duration: RAMP, target }, { duration: HOLD, target });
  }
  out.push({ duration: '10s', target: 0 });
  return out;
}

// The step a request belongs to: the total VU target of the hold it falls in,
// or "ramp" between holds. From the scenario's start, so a ramp has the same
// shape in every scenario of a run.
export function currentStep() {
  const elapsed = (Date.now() - exec.scenario.startTime) / 1000;
  let t = 0;
  for (const s of STEPS) {
    t += seconds(RAMP);
    if (elapsed < t) return 'ramp';
    t += seconds(HOLD);
    if (elapsed < t) return String(s);
  }
  return 'ramp';
}

// Per-step thresholds: they make k6 compute each step's p95 and error rate
// (a tagged sub-metric only exists if a threshold names it) and mark the steps
// over the SLO. The run as a whole fails from the first step over: expected,
// that is where the knee is.
export function thresholds() {
  const th = {
    checks: ['rate>0.99'],
  };
  for (const s of STEPS) {
    th[`http_req_failed{step:${s}}`] = [`rate<${SLO.errorRate}`];
    th[`http_req_duration{step:${s},kind:read}`] = [`p(95)<${SLO.readP95}`];
    th[`http_req_duration{step:${s},kind:write}`] = [`p(95)<${SLO.writeP95}`];
    th[`http_reqs{step:${s}}`] = ['count>=0'];
  }
  return th;
}

export function baseOptions() {
  return {
    thresholds: thresholds(),
    // Keep latency percentiles worth reading.
    summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
    // The load-test stack is plain http on the compose network.
    insecureSkipTLSVerify: true,
    // One connection per VU, as one phone keeps one.
    noConnectionReuse: false,
  };
}
