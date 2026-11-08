// The headline number: the three services at once, each step's VUs split
// between them (MIX, default 60 % Track Vote, 30 % Playlist Editor, 10 % Control
// Delegation -- a party is mostly people voting). "Simultaneous users" in the
// write-up is this scenario's answer.
// Run: make loadtest SCENARIO=mixed

import { baseOptions, stages } from '../lib/config.js';
import { trackVote, playlistEditor, delegation } from '../lib/behaviours.js';

export { handleSummary } from '../lib/summary.js';

const mix = Object.fromEntries((__ENV.MIX || 'vote:0.6,playlist:0.3,delegation:0.1')
  .split(',').map((kv) => kv.split(':')).map(([k, v]) => [k, Number(v)]));

const scenario = (share, exec) => ({
  executor: 'ramping-vus', startVUs: 0, stages: stages(share), gracefulRampDown: '10s', exec,
});

export const options = {
  ...baseOptions(),
  scenarios: {
    track_vote: scenario(mix.vote, 'trackVote'),
    playlist_editor: scenario(mix.playlist, 'playlistEditor'),
    delegation: scenario(mix.delegation, 'delegation'),
  },
};

export { trackVote, playlistEditor, delegation };
