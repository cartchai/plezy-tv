# PlezTV Build #10 — In-app update download + install (updater notes)

Matt (2026-11-06): "Have it download the latest file itself rather than
open a browser, so the TV can install it once it's done downloading —
give an install option." The old flow (build #6) checked GitHub Releases
and opened the browser to download the APK. On Android TV / Google TV
there is no browser download flow, so the update was effectively
unreachable there.

## What changed

- **New: `lib/services/apk_update_downloader.dart`** — streams the
  release APK to disk in chunks via `package:http` `Client.send` (a
  ~350 MB APK never sits whole in memory); `ApkDownloadController`
  cancels; `formatDownloadBytes` ("12.3 MB" / "845 KB" / "512 B");
  verifies the finished file's size against the release asset size and
  throws `ApkDownloadSizeMismatch` on a truncated download; deletes the
  partial file on failure / cancel / mismatch. `@visibleForTesting
  static http.Client? debugClientOverride` test seam.
- **New: `lib/services/apk_installer.dart`** — opens the system install
  prompt over MethodChannel `com.matt.plezytv/apk_install`
  (`installApk`, `{'filePath': ...}`); returns true when the installer
  opened, false when no handler / non-Android / missing channel; throws
  `ApkInstallException(code, message)` on `PlatformException`.
  `@visibleForTesting static bool? debugPlatformIsAndroid` seam (unit
  tests run on the host platform).
- **New: `android/app/src/main/kotlin/com/matt/plezytv/ApkInstallChannel.kt`**
  — channel `com.matt.plezytv/apk_install`; `FileProvider.getUriForFile`
  (`com.matt.plezytv.fileprovider`), `ACTION_VIEW` +
  `application/vnd.android.package-archive` +
  `FLAG_GRANT_READ_URI_PERMISSION`; errors `INVALID_ARGUMENT` /
  `FILE_NOT_FOUND` / `BAD_FILE` / `failed`.
- **`android/app/src/main/kotlin/com/matt/plezytv/PlezyActivity.kt`** —
  `ApkInstallChannel` attached next to the other channels (~line 976).
- **`android/app/src/main/AndroidManifest.xml`** — added
  `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>`
  after INTERNET.
- **`lib/services/update_service.dart`** — `_apkAsset` now also returns
  `'apkAssetSize'` (the asset `size` from the GitHub API) for the
  downloader's verification.
- **Rewrote `lib/utils/update_dialog.dart`** — stateful dialog:
  info → downloading (progress bar + "X of Y" bytes + Cancel) →
  downloaded/verified → Install (autofocus, D-pad reachable) → system
  install prompt; error states show a clear message with Retry.
  Dismissing mid-download cancels it (dispose cancels the controller).
  Android-only in-app flow; other platforms (and releases with no APK
  asset) keep the old browser "Download APK" button. "View Release" and
  "Skip This Version" kept. The download goes to the app cache dir
  (`pleztv-update.apk`), which the FileProvider `<cache-path>` already
  covers.
- **i18n (`lib/i18n/en.i18n.json`, `update` section, slang regen):**
  `download`, `downloading`, `downloadProgress`, `downloadComplete`,
  `install`, `inAppDownloadHint`, `installUpdateHint`,
  `downloadFailed`, `downloadSizeMismatch`, `downloadCancelled`,
  `installUnavailable`. `installApkHint` kept for the non-Android
  browser flow.

## What did NOT change

Signing, keystore, package name, version handling — untouched. The
fixed debug keystore keeps the signature, so install-over-the-top
works. Version check and "no update available" state unchanged. Update
entry point unchanged (Updates above About). No series search /
library / EPG code touched by this part (those are separate items in
`IPTV_BUILD10_NOTES.md`).

## Tests (all green)

- `test/services/apk_update_downloader_test.dart` (6 tests): chunked
  download + progress order + size verification, size mismatch throws
  and deletes the partial file, HTTP error throws and deletes the
  partial, cancel mid-download throws and deletes the partial, unknown
  total reports -1 and still completes, `formatDownloadBytes`.
- `test/services/apk_installer_test.dart` (5 tests): channel method
  name + `filePath` arg, returns true; false on no handler; false on
  non-Android without touching the channel; `PlatformException` →
  `ApkInstallException` with the native code; missing channel → false.
- `test/services/update_service_test.dart` (+1): the release asset
  size rides along with the URL (`apkAssetSize`).
- `test/utils/update_dialog_test.dart` (3 widget tests): Android
  Download fetches the APK in-app and Install opens the installer
  (file lands at `pleztv-update.apk`, 1000 bytes in the fake);
  truncated download shows the retry message; non-Android keeps the
  browser "Download APK" button. Real file I/O inside `testWidgets`
  needs `tester.runAsync` — without it the download stalls at the
  first real write (fake-async zone never delivers the I/O
  completion) and `pumpAndSettle` returns with nothing rendered.
  Lesson worth keeping: any widget test that touches real dart:io must
  drive that part in `runAsync`.

## Proven by test vs needs Matt's phone

- Proven: chunked download, progress order, size verification,
  mismatch/cancel/error cleanup, installer channel call + args, the
  asset-size plumbing, the dialog's state walk (info → downloading →
  downloaded → Install) and its browser fallback.
- Unproven until his phone: the real GitHub download end to end, the
  actual system install prompt on a phone AND on a TV (including the
  first-use "Install unknown apps" allow step for PlezTV), and the
  install-over-the-top on the real device (cert matches the fixed
  keystore, but per the release skill that is NOT proof until the phone
  installs it).
