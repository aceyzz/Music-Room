// Playlist Editor: members of shared playlists editing the same rows at once.
// One service alone, stepped ramp: lib/config.js. Run: make loadtest SCENARIO=playlist_editor

import { baseOptions, stages } from '../lib/config.js';
import { playlistEditor } from '../lib/behaviours.js';

export { handleSummary } from '../lib/summary.js';

export const options = {
  ...baseOptions(),
  scenarios: {
    playlist_editor: { executor: 'ramping-vus', startVUs: 0, stages: stages(), gracefulRampDown: '10s', exec: 'playlistEditor' },
  },
};

export { playlistEditor };
