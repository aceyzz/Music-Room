// What one virtual user does per iteration, per service. One iteration is one
// poll of the app's screen (every POLL_SECONDS, like the app) plus, sometimes,
// a tap. The rates below are guesses at an engaged user, written down so the
// result can be read against them (docs/load-testing.md, "Load profile").

import { sleep } from 'k6';
import { POLL_SECONDS, me, meIndex, events, playlists, circles, songs, users, demoEvent, pickOne } from './config.js';
import * as api from './api.js';

function think() {
  // +-20 % so the VUs do not poll in lockstep.
  sleep(POLL_SECONDS * (0.8 + Math.random() * 0.4));
}

// Track Vote: an attendee on the live event page. The host also advances the
// queue every ~30 s, the length of a song (the 30-second Deezer preview).
export const VOTE_RATE = 0.4;
export const SUGGEST_RATE = 0.05;

export function trackVote() {
  const u = me();
  const event = events[u.event];
  api.getPlayback(u.token, event.publicId);
  const queue = api.listQueue(u.token, event.publicId);

  if (event.host === meIndex() && Math.random() < POLL_SECONDS / 30) {
    api.playNext(u.token, event.publicId);
  }
  const votable = queue.filter((e) => !e.viewerHasVoted);
  if (votable.length > 0 && Math.random() < VOTE_RATE) {
    api.castVote(u.token, event.publicId, pickOne(votable).publicId);
  }
  if (Math.random() < SUGGEST_RATE) {
    api.suggestSong(u.token, event.publicId, pickOne(songs));
  }
  think();
}

// Playlist Editor: a member on the playlist page, editing now and then. Every
// member of a playlist edits the same rows, which is the contention the
// revision lock exists for (docs/data-model.md §13).
export const ADD_RATE = 0.06;
export const MOVE_RATE = 0.12;
export const REMOVE_RATE = 0.04;

export function playlistEditor() {
  const u = me();
  const playlist = playlists[u.playlist].publicId;
  const rows = api.getPlaylist(u.token, playlist).songs || [];

  const r = Math.random();
  if (r < ADD_RATE) {
    api.addSong(u.token, playlist, pickOne(songs));
  } else if (r < ADD_RATE + MOVE_RATE && rows.length > 2) {
    const row = pickOne(rows);
    // After another row, or to the top one time in five.
    const after = Math.random() < 0.2 ? 0 : pickOne(rows.filter((x) => x.id !== row.id)).id;
    api.moveSong(u.token, playlist, row.id, after);
  } else if (r < ADD_RATE + MOVE_RATE + REMOVE_RATE && rows.length > 10) {
    api.removeSong(u.token, playlist, pickOne(rows).id);
  }
  think();
}

// Control Delegation: the device owner churns a grant to the circle's spare
// friend (grant one iteration, revoke the next); the delegates drive the
// circle's event with the owner's device; the spare only watches.
export const PLAYBACK_RATE = 0.3;

let spareLicense = null; // per VU: the grant this owner made and has not revoked yet

export function delegation() {
  const u = me();
  const circle = circles[u.circle];
  const i = meIndex();

  if (circle.owner === i) {
    api.listLicenses(u.token, circle.device);
    if (circle.spare >= 0) {
      if (spareLicense === null) {
        const license = api.grantControl(u.token, circle.device, users[circle.spare].publicId, circle.event);
        spareLicense = license ? license.id : null;
      } else {
        api.revokeControl(u.token, circle.device, spareLicense);
        spareLicense = null;
      }
    }
  } else {
    api.getPlayback(u.token, circle.event);
    if (circle.delegates.includes(i) && Math.random() < PLAYBACK_RATE) {
      api.setPlayback(u.token, circle.event, Math.random() < 0.5);
    }
  }
  think();
}

// make loadtest-demo: bots in the demo event Alex has open on the phone. Public
// event, "everyone" licence: any signed-in user may vote there.
export function demoCrowd() {
  const u = me();
  const queue = api.listQueue(u.token, demoEvent);
  const votable = queue.filter((e) => !e.viewerHasVoted);
  if (votable.length > 0 && Math.random() < 0.3) {
    // Favour the top of the queue a little, so the order visibly shifts.
    const top = votable.slice(0, Math.max(3, Math.ceil(votable.length / 3)));
    api.castVote(u.token, demoEvent, pickOne(Math.random() < 0.6 ? top : votable).publicId);
  }
  if (Math.random() < 0.03) {
    api.suggestSong(u.token, demoEvent, pickOne(songs));
  }
  think();
}
