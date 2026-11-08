// Control Delegation: owners churning grants, delegates driving playback with the owner's device.
// One service alone, stepped ramp: lib/config.js. Run: make loadtest SCENARIO=delegation

import { baseOptions, stages } from '../lib/config.js';
import { delegation } from '../lib/behaviours.js';

export { handleSummary } from '../lib/summary.js';

export const options = {
  ...baseOptions(),
  scenarios: {
    delegation: { executor: 'ramping-vus', startVUs: 0, stages: stages(), gracefulRampDown: '10s', exec: 'delegation' },
  },
};

export { delegation };
