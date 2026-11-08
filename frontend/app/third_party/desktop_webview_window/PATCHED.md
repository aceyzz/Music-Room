# desktop_webview_window 0.3.0, patched

A copy of https://pub.dev/packages/desktop_webview_window 0.3.0 (Apache 2.0,
LICENSE), pinned by `dependency_overrides` in the app's pubspec.yaml. The app
does not use it directly: flutter_web_auth_2 opens its login window on Linux
and Windows with it. Only `linux/webview_window.{h,cc}` differ from upstream;
every change is marked `PATCHED (music-room)`.

On the eval phone (the Linux build on Xvfb, `frontend/Dockerfile`), upstream
crashed the app every time the login window closed (the redirect caught, or
the close button), so a 42 or Google sign-in never reached OAuthLogin and the
restarted app showed the login page again. Two causes:

1. **Use after free.** The window's `destroy` handler called the plugin's
   close callback, which deletes the `WebviewWindow`, then read its id and
   method channel to send `onWindowClose`. Now it sends first. The
   destructor also disconnects the web view's signals, which still pointed
   at the deleted object.
2. **A second Flutter engine for the title bar.** Upstream drew it with
   `fl_view_new`, running the app's main with `web_view_title_bar <id>`
   (hence `runWebViewTitleBarWidget`). Tearing that engine down raised a GLX
   `BadAccess` on a screen without a GPU, fatal under GDK. It is now two GTK
   buttons, ✕ (close = cancel) and ← (back); the Dart title bar API
   (`runWebViewTitleBarWidget`, `TitleBarWebViewController`) does nothing.

To update: take the new upstream, reapply the marked hunks, or drop the copy
if upstream fixed both.
