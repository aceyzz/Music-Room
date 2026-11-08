// The phone's sound, which noVNC does not carry, added to noVNC's own
// vnc.html (frontend/Dockerfile) so it is there whatever URL opened the
// screen. Raw PCM from PulseAudio over a WebSocket (entrypoint.sh), played
// with the Web Audio API about 100 ms behind the app: an <audio> element on
// a compressed stream would buffer seconds of it, like a radio.
//
// On by default: it starts at once if the browser allows it, otherwise on the
// first click or key anywhere on the page (browsers do not start audio before
// the user has interacted). The button mutes it.
//
// The stream is 10 ports above the screen: 6080 -> 6090, 6081 -> 6091
// (docker-compose.yaml, phone and phone-2).
(() => {
  const RATE = 48000; // s16le, 2 channels: entrypoint.sh's module-simple-protocol-tcp
  const AHEAD = 0.1; // seconds queued ahead of what is heard
  const MAX_AHEAD = 0.3; // past this, drop what is queued and catch up
  const url = `ws://${location.hostname}:${Number(location.port) + 10}/`;

  const button = document.createElement('button');
  button.style.cssText = 'position:fixed;top:8px;right:8px;z-index:10000;padding:6px 12px;'
    + 'border:0;border-radius:16px;font:14px sans-serif;cursor:pointer';
  let muted = false;
  let ctx = null;
  let socket = null;
  let nextAt = 0;
  let leftover = new Uint8Array(0); // a frame split across two messages

  const play = (bytes) => {
    // Whole frames only (2 channels x 2 bytes); keep the rest for next time.
    const data = new Uint8Array(leftover.length + bytes.length);
    data.set(leftover);
    data.set(bytes, leftover.length);
    const usable = data.length - (data.length % 4);
    leftover = data.slice(usable);
    if (usable === 0) return;

    const samples = new Int16Array(data.buffer, 0, usable / 2);
    const frames = samples.length / 2;
    const buffer = ctx.createBuffer(2, frames, RATE);
    const left = buffer.getChannelData(0);
    const right = buffer.getChannelData(1);
    for (let i = 0; i < frames; i++) {
      left[i] = samples[2 * i] / 32768;
      right[i] = samples[2 * i + 1] / 32768;
    }
    const now = ctx.currentTime;
    if (nextAt < now || nextAt > now + MAX_AHEAD) nextAt = now + AHEAD;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    source.start(nextAt);
    nextAt += buffer.duration;
  };

  const start = () => {
    if (muted) return;
    ctx ??= new AudioContext({ sampleRate: RATE });
    ctx.resume(); // refused until the first interaction; retried on each
    if (socket) return;
    socket = new WebSocket(url, ['binary']);
    socket.binaryType = 'arraybuffer';
    socket.onmessage = (event) => {
      if (ctx.state === 'running') play(new Uint8Array(event.data));
    };
    socket.onclose = () => {
      socket = null;
      // The phone restarting: come back with it.
      if (!muted) setTimeout(start, 1000);
    };
  };
  const stop = () => {
    socket?.close();
    socket = null;
    ctx?.suspend();
  };
  const render = () => { button.textContent = muted ? '🔊 Sound' : '🔇 Mute'; };

  button.onclick = (event) => {
    event.stopPropagation();
    muted = !muted;
    muted ? stop() : start();
    render();
  };
  // Capture phase: noVNC's canvas would otherwise keep the clicks to itself.
  for (const type of ['pointerdown', 'keydown']) {
    document.addEventListener(type, start, { capture: true });
  }

  render();
  document.body.appendChild(button);
  start();
})();
