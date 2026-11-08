// The REST calls the scenarios make, one function per RPC.
//
// REST through the gateway, not gRPC: the gateway path is gateway -> gRPC ->
// handler, so it does strictly more work per request than the app's direct gRPC
// call, and the numbers are a conservative bound for it.
//
// Every request is tagged:
//   name  the RPC, so the report groups by call rather than by URL (every URL
//         carries a public id; untagged, each would be its own series)
//   kind  read or write, for the two latency SLOs
//   step  the ramp step it ran in (config.js currentStep)
// and declares which statuses are part of the protocol rather than failures:
// a vote on a song that just started playing, a move under a row another
// editor just removed, a second grant of the same scope. Those count in
// `conflicts`, not in http_req_failed -- the server answering "no" correctly
// under contention is the behaviour being tested, not an error.

import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE_URL, currentStep } from './config.js';

export const conflicts = new Counter('conflicts');
// What loadtest/verify compares with the database after the run.
export const votesAccepted = new Counter('votes_accepted');
export const playlistMutations = new Counter('playlist_mutations');

const OK = [200];

function call(method, path, body, token, name, kind, expected = OK) {
  const params = {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    tags: { name, kind, step: currentStep() },
    responseCallback: http.expectedStatuses(...expected),
  };
  const res = http.request(method, `${BASE_URL}${path}`, body === null ? null : JSON.stringify(body), params);
  check(res, { [`${name} answered as expected`]: (r) => expected.includes(r.status) });
  if (res.status !== 200 && expected.includes(res.status)) {
    conflicts.add(1, { name });
  }
  return res;
}

function json(res) {
  try {
    return res.json();
  } catch (_) {
    return {};
  }
}

// --- Track Vote -----------------------------------------------------------------

export function listQueue(token, event) {
  const res = call('GET', `/v1/events/${event}/queue`, null, token, 'ListEventQueue', 'read');
  return json(res).queue || [];
}

export function getPlayback(token, event) {
  return call('GET', `/v1/events/${event}/playback`, null, token, 'GetEventPlayback', 'read');
}

// 200 with accepted=false when the user already voted for it or it is no
// longer queued; 400/404 when it left the queue between the read and the vote.
export function castVote(token, event, entry) {
  const res = call('POST', `/v1/events/${event}/queue/${entry}/vote`, {}, token, 'CastVote', 'write',
    [200, 400, 404, 409]);
  if (res.status === 200 && json(res).accepted) {
    votesAccepted.add(1);
  }
  return res;
}

// 409 when the song is already queued.
export function suggestSong(token, event, deezerSongId) {
  return call('POST', `/v1/events/${event}/queue`, { deezer_song_id: deezerSongId }, token,
    'SuggestSong', 'write', [200, 400, 409]);
}

// 400 (FAILED_PRECONDITION) when the queue is empty.
export function playNext(token, event) {
  return call('POST', `/v1/events/${event}/playback/next`, {}, token, 'PlayNextInEventQueue', 'write',
    [200, 400]);
}

// A delegate's licence is checked against the event's speaker: no device named.
export function setPlayback(token, event, isPaused) {
  return call('PATCH', `/v1/events/${event}/playback`, { is_paused: isPaused }, token,
    'SetEventPlayback', 'write');
}

// --- Playlist Editor --------------------------------------------------------------

export function getPlaylist(token, playlist) {
  const res = call('GET', `/v1/playlists/${playlist}`, null, token, 'GetPlaylist', 'read');
  return json(res);
}

export function addSong(token, playlist, deezerSongId) {
  const res = call('POST', `/v1/playlists/${playlist}/songs`,
    { deezer_song_id: deezerSongId, allow_duplicate: true }, token, 'AddSongToPlaylist', 'write');
  if (res.status === 200) playlistMutations.add(1);
  return res;
}

// 404 / 400 when the row (or the one to land after) was removed by someone
// else since this client's last read -- the conflict the app shows and reloads.
export function moveSong(token, playlist, rowId, afterRowId) {
  const res = call('PATCH', `/v1/playlists/${playlist}/songs/${rowId}/position`,
    { after_playlist_song_id: afterRowId }, token, 'MoveSongInPlaylist', 'write', [200, 400, 404, 409]);
  if (res.status === 200) playlistMutations.add(1);
  return res;
}

export function removeSong(token, playlist, rowId) {
  const res = call('DELETE', `/v1/playlists/${playlist}/songs/${rowId}`, null, token,
    'RemoveSongFromPlaylist', 'write', [200, 404]);
  if (res.status === 200) playlistMutations.add(1);
  return res;
}

// --- Control Delegation -------------------------------------------------------------

// For one event, which the server requires; 409 when it is already granted.
export function grantControl(token, device, grantee, event) {
  const res = call('POST', `/v1/devices/${device}/control-licenses`,
    { grantee_user_public_id: grantee, event_public_id: event },
    token, 'GrantDeviceControl', 'write', [200, 409]);
  return json(res).license;
}

export function revokeControl(token, device, licenseId) {
  return call('DELETE', `/v1/devices/${device}/control-licenses/${licenseId}`, null, token,
    'RevokeDeviceControl', 'write', [200, 404]);
}

export function listLicenses(token, device) {
  const res = call('GET', `/v1/devices/${device}/control-licenses`, null, token,
    'ListDeviceControlLicenses', 'read');
  return json(res).licenses || [];
}

// --- Auth ------------------------------------------------------------------------------

export function login(email, password) {
  const res = http.post(`${BASE_URL}/v1/auth/login`, JSON.stringify({ email, password }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'Login', kind: 'write', step: currentStep() },
  });
  check(res, { 'Login answered 200': (r) => r.status === 200 });
  return res;
}
