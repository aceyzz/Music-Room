// The phone's position, which the demo phone has no GPS for: a 📍 button over
// the screen, next to the Sound one, picks it. position.py writes it where the
// app reads it (FilePositionSource), for the events that only count votes from
// their venue (vote licence location_time). Added to noVNC's vnc.html, like
// sound.js (frontend/Dockerfile).
//
// The endpoint is 20 ports above the screen: 6080 -> 6100, 6081 -> 6101
// (docker-compose.yaml, phone and phone-2), so each phone has its own.
(() => {
  const url = `http://${location.hostname}:${Number(location.port) + 20}/position`;
  const places = [
    ['Paris', '48.8566,2.3522'],
    ['Lyon', '45.764,4.8357'],
    ['Marseille', '43.2965,5.3698'],
    // Rue de Lausanne 64, Renens: near enough (~100 m) for a venue radius.
    ['42 Lausanne', '46.5374,6.589'],
  ];

  const style = 'border:0;border-radius:16px;font:14px sans-serif;cursor:pointer;padding:6px 12px';
  const button = document.createElement('button');
  button.style.cssText = `position:fixed;top:8px;right:100px;z-index:10000;${style}`;
  const menu = document.createElement('div');
  menu.style.cssText = 'position:fixed;top:44px;right:100px;z-index:10000;display:none;'
    + 'flex-direction:column;gap:4px;padding:6px;border-radius:12px;background:#fff;'
    + 'box-shadow:0 2px 8px rgba(0,0,0,.25)';

  const nameOf = (position) =>
    position === 'off' ? 'Off' : (places.find(([, p]) => p === position)?.[0] ?? position);
  const render = (position) => { button.textContent = `📍 ${nameOf(position)}`; };

  const set = async (position) => {
    try {
      const answer = await fetch(url, { method: 'PUT', body: position });
      const text = await answer.text();
      if (!answer.ok) {
        alert(text);
        return;
      }
      render(text);
    } catch (error) {
      alert(`The phone's position could not be set: ${error}`);
    }
  };

  const item = (label, onPick) => {
    const entry = document.createElement('button');
    entry.textContent = label;
    entry.style.cssText = `${style};background:#eef2f8;text-align:left`;
    entry.onclick = (event) => {
      event.stopPropagation();
      menu.style.display = 'none';
      onPick();
    };
    menu.append(entry);
  };
  for (const [label, position] of places) item(label, () => set(position));
  item('Other…', () => {
    const typed = prompt('Latitude,longitude (e.g. 48.8566,2.3522)');
    if (typed) set(typed.trim());
  });
  item('Off: no position', () => set('off'));

  button.onclick = (event) => {
    event.stopPropagation();
    menu.style.display = menu.style.display === 'none' ? 'flex' : 'none';
  };
  document.addEventListener('click', () => { menu.style.display = 'none'; });

  render('off');
  // What the phone already has (a reload keeps it: the file outlives the page).
  fetch(url).then((answer) => answer.text()).then(render).catch(() => {});
  document.body.append(button, menu);
})();
