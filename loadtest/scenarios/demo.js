// make loadtest-demo, for the evaluation: DEMO_VUS bots voting in the demo
// event (seed: "Friday Warm-up — Live") while Alex has it open on the phone, so
// the queue reorders live on screen and the k6 dashboard (:5665) shows the load
// next to it. A fixed load, not a ramp: it shows the behaviour, the other
// scenarios measure the limit.

import { baseOptions, demoEvent } from '../lib/config.js';
import { demoCrowd } from '../lib/behaviours.js';

export { handleSummary } from '../lib/summary.js';

if (!demoEvent) {
  throw new Error('fixtures.json has no demoEvent: seed with the demo world (make loadtest-demo-seed)');
}

export const options = {
  ...baseOptions(),
  scenarios: {
    demo: {
      executor: 'constant-vus', vus: Number(__ENV.DEMO_VUS || 100), duration: __ENV.DEMO_DURATION || '10m',
      exec: 'demoCrowd',
    },
  },
};

export { demoCrowd };
