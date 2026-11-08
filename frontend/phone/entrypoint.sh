#!/bin/sh
# The phone container (frontend/Dockerfile, target phone): a virtual screen,
# the Music Room Linux app full screen on it, and the screen in a browser.
#
#   Xvfb :0             the screen, phone-sized (PHONE_SCREEN, WIDTHxHEIGHT)
#   matchbox            the window manager: every window full screen, no title bar
#   x11vnc  :5900       the screen over VNC, container-local only
#   websockify :6080    noVNC, the VNC client in the browser, + the VNC socket
#   pulseaudio          the sound card: a null sink, "music", the app plays into
#   websockify :6090    that sink as raw PCM, for sound.js (noVNC has no audio)
#   position.py :6100   the phone's position, set with position.js's 📍 button
#   dbus + gnome-keyring  libsecret's Secret Service: where
#                       flutter_secure_storage keeps the session token
set -eu

export DISPLAY=:0
SCREEN="${PHONE_SCREEN:-412x915}"

# A container restarted rather than recreated (docker restart, the machine
# rebooting) keeps its /tmp: the previous Xvfb's lock and socket are still
# there, and Xvfb refuses to start ("Server is already active for display
# 0") while the wait below sees the old socket and moves on -- the app then
# loops on "cannot open display". Nothing else runs yet, so they are stale.
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

Xvfb :0 -screen 0 "${SCREEN}x24" +extension GLX -nolisten tcp &
i=0
until [ -e /tmp/.X11-unix/X0 ]; do
	i=$((i + 1))
	[ $i -gt 100 ] && { echo "Xvfb did not start" >&2; exit 1; }
	sleep 0.1
done

matchbox-window-manager -use_titlebar no -use_cursor yes &
x11vnc -display :0 -localhost -forever -shared -nopw -quiet -rfbport 5900 &
websockify --web /usr/share/novnc 6080 localhost:5900 >/dev/null 2>&1 &

# No real sound card: a null sink. Its monitor is served as raw PCM on
# 127.0.0.1:4712 (48 kHz s16le stereo, what sound.js expects), and websockify
# turns that into a WebSocket for the page. The unix socket is named so the
# app (libmpv) finds it without a session around it.
export PULSE_SERVER=unix:/tmp/pulse.sock
pulseaudio --daemonize=yes --exit-idle-time=-1 -n \
	--load="module-native-protocol-unix socket=/tmp/pulse.sock auth-anonymous=1" \
	--load="module-null-sink sink_name=music" \
	--load="module-simple-protocol-tcp source=music.monitor record=true playback=false listen=127.0.0.1 port=4712 rate=48000 format=s16le channels=2" \
	2>/dev/null
websockify 6090 localhost:4712 >/dev/null 2>&1 &

# No GPS either: the 📍 button on the page (position.js) sets the phone's
# position through this, in the file the app reads (FilePositionSource,
# demoPositionFile). Off until someone picks one.
mkdir -p /tmp/music-room
[ -f /tmp/music-room/position ] || printf off > /tmp/music-room/position
python3 /opt/phone/position.py 6100 /tmp/music-room/position &

# No photos on a virtual phone: docker-compose.yaml mounts
# frontend/phone/pictures as ~/Pictures. A bookmark puts it in the file
# dialog's sidebar, which opens on an empty "Recent" otherwise.
mkdir -p "$HOME/.config/gtk-3.0"
printf 'file://%s/Pictures Pictures\n' "$HOME" > "$HOME/.config/gtk-3.0/bookmarks"

# The keyring --unlock creates is "login", but libsecret stores in the
# collection aliased "default", and with no alias set it asks, in a dialog on
# the phone's screen, for a password for a new one. The alias file names it.
mkdir -p "$HOME/.local/share/keyrings"
printf login > "$HOME/.local/share/keyrings/default"

# One D-Bus session for the keyring and the app, so the keyring outlives an
# app restart: the token it holds keeps the user signed in. The keyring is
# created and unlocked from stdin, with a fixed password since there is no one
# to type it: the container is the boundary, as on any test device. Not an
# empty one: from an empty password --unlock creates no keyring at all.
# The loop brings the app back when it exits (closed, or crashed): with no
# launcher on the screen, nothing else could.
exec dbus-run-session -- sh -c '
	printf phone | gnome-keyring-daemon --unlock --components=secrets >/dev/null
	while true; do
		/opt/music-room/app
		echo "app exited ($?), restarting" >&2
		sleep 1
	done
'
