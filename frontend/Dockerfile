# The Flutter app, generated and built with Docker alone -- for the evaluation
# machines, which have Docker and nothing else (no Flutter, no Android SDK, no
# protoc plugins).
#
# Build context: the repository root, not frontend/ -- the protos and the buf
# config live up there. frontend/Dockerfile.dockerignore keeps the context to
# what this file copies. Build the APK for linux/amd64 (the Makefile passes it):
# the Android SDK's aapt2 has no linux-arm64 build, so on an Apple Silicon Mac
# that runs emulated -- slowly, but it runs. The phone needs no Android SDK and
# builds natively anywhere.
#
# Targets (`docker build --target <t> --output <dir>`):
#   gen      lib/gen/ alone: the Dart stubs, the merged spec and the OpenAPI
#            client, what `make generate` puts there on a host with the tools
#   app-test the app's sources and Flutter, to run its tests in
#            (`make docker-app-test`)
#   apk-out  music-room.apk alone, release mode, arm64 (real phones) + x86_64
#            (emulators), `make apk`, BACKEND_HOST = the machine's LAN address
#   phone    the Linux build of the app on a virtual screen, in a browser
#            through noVNC (:6080): the evaluation's phone (`make phone`)
#
# lib/gen is gitignored, so like backend/Dockerfile this generates it rather
# than expecting it from the host.

# One version for both Flutters below: the APK's image and the Linux-only SDK.
ARG FLUTTER_VERSION=3.44.0
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:${FLUTTER_VERSION}

# --- Go-built code generation tools ------------------------------------------
# On the build machine's own platform, cross-compiled to the target's: under
# emulation a Go build takes minutes, natively seconds.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS tools
ARG TARGETARCH
# Same versions as the Makefile's `tools` target.
ARG BUF_VERSION=v1.47.2
ARG GRPC_GATEWAY_VERSION=v2.30.0
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go install github.com/bufbuild/buf/cmd/buf@${BUF_VERSION} && \
    CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2@${GRPC_GATEWAY_VERSION} && \
    mkdir /out && \
    # go install puts cross-compiled binaries under bin/linux_<arch>/, native ones in bin/.
    if [ -d /go/bin/linux_$TARGETARCH ]; then cp /go/bin/linux_$TARGETARCH/* /out/; \
    else cp /go/bin/buf /go/bin/protoc-gen-openapiv2 /out/; fi

# --- Flutter for Linux only ---------------------------------------------------
# The base of the phone's build and of the Dart code generation: Ubuntu, the
# Flutter SDK at FLUTTER_VERSION, and only the Linux artifacts. FLUTTER_IMAGE
# carries the Android SDK, ~7 GB that only the APK needs: more than an
# evaluation machine's disk.
# The Flutter Linux toolchain, plus what the plugins with a Linux half link
# against: libsecret (flutter_secure_storage), webkit2gtk (desktop_webview_window,
# pulled in by flutter_web_auth_2), libmpv (media_kit, just_audio's Linux half).
# jni needs no JDK: without one it builds against the headers it ships.
FROM ubuntu:24.04 AS flutter-linux
ARG FLUTTER_VERSION
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git unzip xz-utils \
        clang cmake make ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
        libsecret-1-dev libjsoncpp-dev libwebkit2gtk-4.1-dev libmpv-dev && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
# The plugins' native builds run CMake with its defaults: `make`, and the cc
# and c++ compilers, which are clang here.
# TAR_OPTIONS: precache unpacks its .tgz artifacts with the system tar, and tar
# run as root restores the owner recorded in the archive (uid 397546, gid 5000,
# Google's build machine). Under rootless Docker or userns-remap, the usual
# setup on a Linux machine without sudo, root in the build maps to a subuid
# range (65536 ids) that has no such uid, so chown fails with "Invalid
# argument" and precache aborts. Docker Desktop on a Mac maps every uid, which
# is why it builds there. --no-same-owner leaves the files owned by root.
ENV PATH=/opt/flutter/bin:$PATH CC=clang CXX=clang++ TAR_OPTIONS=--no-same-owner
RUN flutter config --no-analytics --no-enable-android --no-enable-web --enable-linux-desktop >/dev/null && \
    flutter precache --linux --no-android --no-ios --no-web --no-macos --no-windows --no-fuchsia

# --- Dart stubs + merged OpenAPI spec -----------------------------------------
FROM flutter-linux AS dart-gen
ARG PROTOC_PLUGIN_VERSION=25.0.0
RUN dart pub global activate protoc_plugin ${PROTOC_PLUGIN_VERSION}
ENV PATH=$PATH:/root/.pub-cache/bin
COPY --from=tools /out/ /usr/local/bin/
WORKDIR /src
COPY buf.yaml buf.lock buf.gen.frontend.yaml ./
COPY proto proto
# buf fetches the googleapis/grpc-gateway deps pinned in buf.lock: needs network.
RUN buf generate --template buf.gen.frontend.yaml

# --- OpenAPI Dart client + the api.dart barrel ----------------------------------
# Same arguments as the Makefile's generate-openapi.
FROM openapitools/openapi-generator-cli:v7.25.0 AS openapi
COPY --from=dart-gen /src/frontend/app/lib/gen/ /work/gen/
RUN java -jar /opt/openapi-generator/modules/openapi-generator-cli/target/openapi-generator-cli.jar generate \
        -i /work/gen/api_spec.swagger.json \
        -g dart \
        -o /work/gen/openapi_client \
        --additional-properties=pubName=openapi_client \
        --additional-properties=nullableFields=false,legacyDiscriminatorBehavior=false \
        --global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false
COPY frontend/app/tool/write_api_barrel.sh /usr/local/bin/
RUN write_api_barrel.sh /work/gen

FROM scratch AS gen
COPY --from=openapi /work/gen/ /

# --- The app's tests -------------------------------------------------------------
# `make docker-app-test` runs `flutter test` in it, `make docker-app-test-live`
# runs test/live against the stack, on the compose network.
FROM flutter-linux AS app-test
WORKDIR /src/frontend/app
COPY frontend/app/pubspec.yaml frontend/app/pubspec.lock ./
COPY frontend/app/third_party ./third_party
RUN flutter pub get
COPY frontend/app ./
COPY --from=gen / lib/gen/
# test/live reads the mailed codes with `docker logs music-room-backend`: the
# CLI here, the host's daemon through its socket (docker-app-test-live).
COPY --from=docker:27.5.1-cli /usr/local/bin/docker /usr/local/bin/docker
CMD ["flutter", "test"]

# --- The APK -------------------------------------------------------------------
FROM ${FLUTTER_IMAGE} AS apk
# Same reason as in flutter-linux: any artifact Flutter still unpacks here.
ENV TAR_OPTIONS=--no-same-owner

# frontend/app/android/gradle.properties asks for an 8 GB heap, sized for a
# developer machine; on an evaluation machine that also runs the stack it is
# the build that gets killed. The user-home gradle.properties
# wins over the project's, so the repo file stays as it is.
# File watching is for incremental IDE builds; under emulation (an Apple
# Silicon Mac building amd64) its inotify poll throws on every build.
RUN mkdir -p /root/.gradle && printf '%s\n' \
    'org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError' \
    'org.gradle.daemon=false' \
    'org.gradle.vfs.watch=false' > /root/.gradle/gradle.properties

# Every SDK package the Gradle build asks for, installed here rather than by AGP
# on demand. When AGP 8.13 installs a package in the middle of a build, it
# then fails to find API 37 ("Failed to find target with hash string
# 'android-37'"), the package it compiles against (android/app/build.gradle.kts,
# flutter_secure_storage) and which the SDK now ships as
# "platforms;android-37.0". With everything present up front it is found.
# Keep the list in step with what the build reports installing ("Installing
# ... in /opt/android-sdk-linux/...") after a Flutter or plugin upgrade.
ARG NDK_VERSION=28.2.13676358
RUN yes | sdkmanager "platforms;android-37.0" "platforms;android-35" "build-tools;35.0.0" \
        "ndk;${NDK_VERSION}" "cmake;3.22.1" >/dev/null

WORKDIR /src/frontend/app
# Dependencies first: this layer stays cached until pubspec.lock changes.
COPY frontend/app/pubspec.yaml frontend/app/pubspec.lock ./
# The patched desktop_webview_window (a path override): pub resolves it here.
COPY frontend/app/third_party ./third_party
RUN flutter pub get
COPY frontend/app ./
COPY --from=gen / lib/gen/

# Baked in at compile time (lib/globals/app_constants.dart reads
# String.fromEnvironment). A real phone reaches the backend through the
# machine's LAN address, which `make apk` passes; there is no useful default.
ARG BACKEND_HOST=localhost
ARG BACKEND_PORT=50051
ARG BACKEND_HTTP_PORT=8081

# The caches hold what Gradle downloads on a first build (its distribution,
# the Maven artifacts), so a rebuild after a code change does not fetch them
# again. Not the SDK: that is installed above, in the image.
RUN --mount=type=cache,target=/root/.gradle/caches \
    --mount=type=cache,target=/root/.gradle/wrapper \
    flutter build apk --release --target-platform android-arm64,android-x64 \
        --dart-define=BACKEND_HOST=${BACKEND_HOST} \
        --dart-define=BACKEND_PORT=${BACKEND_PORT} \
        --dart-define=BACKEND_HTTP_PORT=${BACKEND_HTTP_PORT}

FROM scratch AS apk-out
COPY --from=apk /src/frontend/app/build/app/outputs/flutter-apk/app-release.apk /music-room.apk

# --- The Linux desktop app -------------------------------------------------------
# What `make phone` shows. The evaluation machines have no /dev/kvm, and an
# x86_64 Android emulator refuses to boot without it, so the demo "phone" is
# the Linux build of the same app: it takes the same native path as Android
# (gRPC, not the web REST code), only the window differs.
# Not built FROM the apk stage, though the source steps are the same: there the
# slow sdkmanager layer comes before the sources and stays cached, and the SDK
# is of no use here anyway.
# Native on every platform: arm64 on an Apple Silicon Mac, x86_64 on the
# evaluation machines.
FROM flutter-linux AS linux-build
WORKDIR /src/frontend/app
COPY frontend/app/pubspec.yaml frontend/app/pubspec.lock ./
# The patched desktop_webview_window (a path override): pub resolves it here.
COPY frontend/app/third_party ./third_party
RUN flutter pub get
COPY frontend/app ./
COPY --from=gen / lib/gen/

# The phone container sits on the compose network, so it names the backend
# by its service name.
ARG BACKEND_HOST=backend
ARG BACKEND_PORT=50051
ARG BACKEND_HTTP_PORT=8081
# "Continue with 42 / Google": the apps' public client IDs, which
# docker-compose.yaml takes from APP_OAUTH_*_CLIENT_ID in the root .env (the
# secrets stay with the backend). Empty leaves that button off. The redirect URI keeps its
# default, http://localhost:8081/oauth/callback: the login window stops there
# without loading it (OAuthConfig.catchesRedirect), so `localhost` not being
# the backend in this container does not matter.
ARG OAUTH_INTRA42_CLIENT_ID=
ARG OAUTH_GOOGLE_CLIENT_ID=
RUN flutter build linux --release \
        --dart-define=BACKEND_HOST=${BACKEND_HOST} \
        --dart-define=BACKEND_PORT=${BACKEND_PORT} \
        --dart-define=BACKEND_HTTP_PORT=${BACKEND_HTTP_PORT} \
        --dart-define=OAUTH_INTRA42_CLIENT_ID=${OAUTH_INTRA42_CLIENT_ID} \
        --dart-define=OAUTH_GOOGLE_CLIENT_ID=${OAUTH_GOOGLE_CLIENT_ID} && \
    # build/linux/<x64|arm64>/: one path for the next stage, whatever the arch.
    mv build/linux/*/release/bundle /bundle

# The app alone (`--output`), for make's low-disk build: built, the cache
# dropped, then the phone image made around it with
# `--build-context linux-build=<dir>`, so the Flutter toolchain and the phone
# image never sit on the disk together.
FROM scratch AS linux-bundle
COPY --from=linux-build /bundle /bundle

# --- The phone: the Linux app on a virtual screen, in the browser -------------------
# Xvfb is the screen (phone-sized), matchbox the window manager (one window,
# full screen, no title bar: it was made for phones), x11vnc + noVNC put it in
# a browser at :6080. GL is Mesa's software renderer: there is no GPU either.
# Sound: the app plays through libmpv into a PulseAudio null sink, whose raw
# PCM websockify serves on :6090, since noVNC carries no audio; sound.js plays
# it in the page, with a Mute button over the screen.
# The 42 login window is WebKitGTK: glib-networking is its TLS (a recommends,
# which --no-install-recommends skips: every https page would fail).
# Ubuntu 24.04, flutter-linux's base, so the bundle finds the libraries it was
# linked against.
FROM ubuntu:24.04 AS phone
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify matchbox-window-manager \
        dbus dbus-x11 gnome-keyring \
        libgtk-3-0t64 libsecret-1-0 libjsoncpp25 libwebkit2gtk-4.1-0 glib-networking \
        libgl1-mesa-dri libglx-mesa0 libegl1 \
        libmpv2 pulseaudio \
        fonts-roboto fonts-noto-color-emoji ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# http://localhost:6080 opens the screen directly, as docker-android's did.
RUN printf '%s\n' '<!doctype html><meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&reconnect=true">' \
        > /usr/share/novnc/index.html
# The Sound and 📍 position buttons, in vnc.html itself so a bookmarked
# vnc.html URL has them too. position.py is what the 📍 one calls (:6100).
COPY frontend/phone/sound.js frontend/phone/position.js /usr/share/novnc/
RUN sed -i 's|</body>|<script src="sound.js"></script><script src="position.js"></script></body>|' \
        /usr/share/novnc/vnc.html
COPY frontend/phone/position.py /opt/phone/position.py
COPY --from=linux-build /bundle /opt/music-room
COPY frontend/phone/entrypoint.sh /usr/local/bin/phone-entrypoint
ENV LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 NO_AT_BRIDGE=1
EXPOSE 6080 6090 6100
ENTRYPOINT ["phone-entrypoint"]
