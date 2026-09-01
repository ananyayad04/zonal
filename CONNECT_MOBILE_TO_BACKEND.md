# Pointing the app at the deployed backend

The app never has the server address hardcoded for good — it's controlled two
ways, and you'll normally only need the first.

## 1. In the app itself (no rebuild needed)

On the **login screen**, at the very bottom, there's a small **server
address** link (a globe/server icon with the current address next to it —
`lib/features/auth/login_screen.dart`, the `_ServerAddress` widget).

1. Tap it.
2. Type your Railway domain, with or without `https://` — just the host is
   enough, e.g.:
   ```
   zonal-production-xxxx.up.railway.app
   ```
3. Tap **Save**.

The app is smart about what you type (`lib/core/config.dart`,
`AppConfig.setBaseUrl`):
- A bare IP like `172.16.3.36` is treated as a dev laptop and gets
  `http://` + `:4000` appended automatically.
- A real hostname (anything with letters, like a `.up.railway.app` domain) is
  treated as a hosted deployment and gets `https://` on the default port —
  nothing else is appended.

This is saved on the device (`shared_preferences`) and survives restarts, so
it's a one-time change per install. Tap **Reset** in the same dialog to go
back to whatever was compiled in.

## 2. At build time (bakes in a default)

If you want a build that talks to Railway **by default**, without anyone
touching the in-app setting, pass the URL when building:

```bash
cd mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://zonal-production-xxxx.up.railway.app
```

or for a debug run against Railway instead of a local server:

```bash
flutter run --dart-define=API_BASE_URL=https://zonal-production-xxxx.up.railway.app
```

Without `--dart-define`, the compiled-in default is `http://localhost:4000`
(see `AppConfig._compiledDefault` in `lib/core/config.dart`) — meant for an
Android emulator or a phone tethered over USB with `adb reverse`, not for a
real deployment.

## Which one to use

- **Testing against Railway from a build you already installed** → use the
  in-app server address field. Fastest, no rebuild.
- **Handing out an APK that should point at Railway out of the box** (e.g. a
  release build for real users) → build with `--dart-define=API_BASE_URL=...`
  so nobody has to configure anything.
