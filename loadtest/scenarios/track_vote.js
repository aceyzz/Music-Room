// Track Vote: attendees on the live event page (poll, vote, suggest; hosts advance the queue).
// One service alone, stepped ramp: lib/config.js. Run: make loadtest SCENARIO=track_vote

import { baseOptions, stages } from '../lib/config.js';
import { trackVote } from '../lib/behaviours.js';

export { handleSummary } from '../lib/summary.js';

export const options = {
  ...baseOptions(),
  scenarios: {
    track_vote: { executor: 'ramping-vus', startVUs: 0, stages: stages(), gracefulRampDown: '10s', exec: 'trackVote' },
  },
};

export { trackVote };
