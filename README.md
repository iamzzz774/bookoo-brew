# BOOKOO Brew

Standalone Flutter Android app for pour-over recording with a BOOKOO Bluetooth
scale, optional BOOKOO MT80 grinder recording, and your own Brew Guide/Supabase
setup. A Mac, desktop broker, pairing code or model service is **not required**.
This is an independent project, not an official BOOKOO application.

## Set up your own services

1. The webpage defaults to `https://coffee.chu3.top/`. You can change it in settings to your own compatible **HTTPS** Brew Guide deployment.
   This repository is the Android shell, not the Brew Guide website/server.
2. In the phone's **设置**, set **Brew Guide 网址** to that deployment's URL.
   Empty/invalid URLs show a configuration prompt without creating a WebView or
   sending a request. Only the configured HTTPS origin (host and effective port)
   is trusted; redirects/navigation to other origins are blocked. A different
   path on the same origin is allowed. Use a direct URL, not an HTTP redirect.
3. Configure the native tab's Supabase URL and client/publishable key for your
   own compatible Brew Guide schema, authentication and row-level policies.
   Never embed a service-role/admin key in an APK, repository or WebView.
   This app does not provision a database, migrate a schema or bypass RLS.
4. Configure/login to Brew Guide **inside the website separately**. Native
   Supabase settings do not automatically configure the website. The embedded
   WebView retains its own cookies/localStorage/IndexedDB, separate from the
   native settings and from a standalone browser. Changing URL does not erase
   either site's stored data; it retires the old page and its pending downloads.
5. Grant the Android Bluetooth permissions when connecting the scale. Release
   other clients' connections if a peripheral is unavailable.

The original Brew Guide website is the default; no Supabase credential is supplied. A local
build can optionally seed the webpage URL with `BREW_GUIDE_URL` via a Dart define
(see below); a compiled-in URL is public to anyone inspecting the APK, not a secret.
Switching ordinary bottom tabs retains the existing page state and layout.

## Optional MT80

Enable **BOOKOO MT80** in settings only if you use that grinder; leave the option
off for a scale-only phone. The phone manages the scale and grinder independently.
There is **no Mac coordination toggle on the phone**. Desktop workflows, if used
separately, are not a prerequisite for recording or saving on the phone.

A complete locally observed IDLE → GRINDING → IDLE episode is preferred at note
save. Otherwise fresh current settings can be saved as a settings snapshot, not
invented grind history. Missing, stale or disconnected readings stay empty.
Snapshots do not claim a grind duration or recovered past event. No Android
background/screen-off capture guarantee is made. Grinder values are the reported
setting in μm and speeds in rpm, not measured particle size. The app's MT80 writes
are limited to the appHello handshake; no start/stop, cleaning or preset control
is exposed. Consult the official BOOKOO protocol documentation for compatible
hardware/firmware. Native brew notes, real curves and inventory sync remain the
recording workflow; there is no recommendation/model service requirement.

## Build prerequisites

- Flutter/Dart compatible with `pubspec.yaml` (Flutter >= 3.41, Dart >= 3.11).
- Android SDK/build tools and the JDK required by the checked-in Android Gradle
  project. Use `flutter doctor -v` to check your machine.
- **Node.js on PATH** for `test/embedded_layout_test.dart` (executes real page
  scripts using Node's built-in `node:assert/strict` and `node:vm`; no npm install).
- Keep `pubspec.lock`; run `flutter pub get` to resolve its pinned packages.

A clean checkout can build debug **without private signing files**:

```sh
flutter pub get
flutter build apk --debug
flutter analyze
flutter test
```

### Release signing

Use **your own existing** `android/key.properties` and private keystore. Its
properties are `storeFile`, `storePassword`, `keyAlias`, `keyPassword`;
`storeFile` is resolved relative to the Android project root unless absolute.
Keep both files private and backed up. Never replace a deployed application's
signer just to make a build succeed: Android updates require the same identity.
The build script does not generate, replace, migrate or print private keys.

```sh
scripts/build_apk.sh --no-bump
```

Without `key.properties`, a release fails with an actionable error rather than
silently changing signer or producing an unsigned distribution. For **local
experiments only**, explicitly permit the standard Android debug-key fallback:

```sh
scripts/build_apk.sh --no-bump --debug-signing
# Equivalent direct build (only when no private key.properties exists):
ORG_GRADLE_PROJECT_bookooAllowDebugSigning=true flutter build apk --release
```

An existing `key.properties` **always wins**, even with the fallback flag. Debug
fallback builds are not production releases and cannot update an installation
signed with somebody else's key. The same application ID also means debug and
release builds are not automatically side-by-side installations.

The script defaults to bumping patch and build number, copies the result to
`build/apk/bookoo_brew-v<version>+<build>.apk`, and retains three recent copies.
`--no-bump`, `--bump build|minor|major|patch`, `--dry-run`, and `--prune-only` are
available. Dry-run does not write the version or start a build.

For a private local URL seed, keep a Dart-define JSON file **outside the export**:

```sh
scripts/build_apk.sh --no-bump -- --dart-define-from-file=/path/to/private-defines.json
```

Do not put a personal endpoint or secret into committed commands, test fixtures,
release notes, screenshots or logs. The default website address is intentionally included; use runtime settings to change it.

## Backend and companion trust boundary

The native app uses the client key supplied in settings; `User ID` is a data
selection field, **not authentication or access control**. This shell does not
implement a user login flow. Review your backend policies before sharing a
project with other users; never substitute a service-role key to bypass RLS.
The phone has no Mac discovery, handoff request, Realtime coordination channel,
or Mac-release wait. It connects directly to its Bluetooth peripherals. Existing
Brew Guide/Supabase network access is for the webpage and brewing data only.
The optional personal Mac recorder follows GG reachability on the Mac itself;
it is not part of the phone application and does not require phone-to-Mac
communication, Tailscale configuration or pairing codes. Other users do not need
a Mac, GG machine or hydration program. A machine left on during pour-over is a
manual-pause exception for the Mac recorder, not a phone setup requirement.

## Embedded WebView boundaries

The configured HTTPS host **and effective port** form the trust boundary (443 is
the HTTPS default). Page scripts recheck that origin at execution time and only
install in the top frame. Camera and file-picker requests require the current
trusted page, and camera is the only granted web permission. Native download
messages additionally require an unguessable per-document capability issued only
to that top-frame script. Navigation or URL changes invalidate pending assembled
downloads; stale controller callbacks cannot affect the new page.

The pinned WebView plugin exposes the current page URL, but does **not** expose
the initiating frame origin for its camera/file-selector callbacks. Therefore
those two checks are a **top-level origin policy**, not proof of an individual
iframe's origin. Deploy only a Brew Guide site you control, avoid untrusted
embedded frames, and serve a restrictive Permissions-Policy/CSP (camera limited
to self, frame-src limited to self). A hostile script served by your configured
origin is trusted code; the shell cannot make that site trustworthy.

## Licenses and public export

Original first-party code is MIT: see [LICENSE](LICENSE). Preserved BOOKOO
upstream attribution, exact pinned pub-package license texts and SDK license
texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `licenses/`.
The package inventory includes development/non-Android dependencies; it is not a
claim that all are shipped. Native Maven/engine notices require separate
release-graph review, as described in the notices file.

Export a reviewed **source allowlist into a fresh history**, not the entire local
working directory or its old `.git/`. Exclude signing files, `local.properties`,
`.dart_tool/`, build outputs (including `android/build/`), private environment/
define files, captures, exported notes and diagnostic logs. `.gitignore` is a
safety net, not a secret scanner and not a way to erase existing Git history.
Before publication, inspect the actual source snapshot and binary separately
for personal URLs/keys, verify the release signature, and complete native
third-party attribution review. Never publish private database records or key
material as test data.
