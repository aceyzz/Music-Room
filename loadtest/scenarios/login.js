// Sign-in throughput, measured apart from everything else. Each Login verifies
// an Argon2id hash with 64 MiB of memory (backend/internal/security/password.go)
// on purpose -- it is what makes a stolen hash expensive to crack -- so logins
// per second, and the memory they take, are a limit of their own. The other
// scenarios start from seeded sessions for exactly that reason.
//
// STEPS here are logins per second, not VUs (ramping-arrival-rate).
// Run: make loadtest SCENARIO=login STEPS=1,2,4,8,16

import { baseOptions, stages, users, pickOne, STEPS } from '../lib/config.js';
import { login } from '../lib/api.js';

export { handleSummary } from '../lib/summary.js';

export const options = {
  ...baseOptions(),
  scenarios: {
    login: {
      executor: 'ramping-arrival-rate', startRate: 0, timeUnit: '1s', stages: stages(),
      preAllocatedVUs: 20, maxVUs: Math.max(50, 4 * Math.max(...STEPS)), exec: 'signIn',
    },
  },
};

export function signIn() {
  login(pickOne(users).email, 'musicroom42');
}
