<h1>
  <img src="assets/plezy.png" alt="PlezTV logo" height="24" style="vertical-align: middle;" />
  PlezTV
</h1>

A fork of [Plezy](https://github.com/edde746/plezy) that adds IPTV: M3U playlists and Xtream Codes accounts, with live TV in the Live TV section and on-demand movies and series in the Library.

<p>
  <a href="#plezy-upstream">Plezy (upstream)</a> ·
  <a href="#what-pleztv-adds">What PlezTV adds</a> ·
  <a href="#install">Install</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

## What PlezTV adds

Everything in Plezy, plus IPTV.

### Shipped in v2.25.0

- **M3U and Xtream Codes import** — Add connection → M3U or Xtream Codes. Each library is given a name when you add it, and labelled by its source (M3U or Xtream Codes).
- **Live TV from IPTV in the Live TV tab** — IPTV channels appear in Live TV, not as a library. A source picker above the guide switches between live TV sources (All sources, or one server at a time).
- **On-demand in the Library** — movies and series from an Xtream account appear as Movies and Series libraries, with Recommended and Browse.
- **Country/region filter** — turn whole categories (countries and regions) on or off per connection, from the connection's edit screen.
- **IPTV settings** — Settings → Connections → IPTV: your IPTV connections, Manage groups with Show all / Hide all, Refresh playlists, and a Show catch-up badge toggle.
- **Catch-up badge** — guide channels that offer catch-up show a badge, so you can see it at a glance.

### In progress for v2.25.1

- Renamed to **PlezTV** throughout the app, with a blue app icon.
- A changelog in the About screen, so you can see what's in each version.
- **First-start IPTV** — add an IPTV connection the first time you open the app, with no Plex account needed.

## Plezy (upstream)

Plezy is a modern client for Plex, Jellyfin, and Emby on desktop, mobile, and TV, built with Flutter. It is a separate project by [edde746](https://github.com/edde746) and contributors — PlezTV is based on Plezy 2.25.0.

- Upstream repo: https://github.com/edde746/plezy
- Upstream releases and updates: https://github.com/edde746/plezy/releases
- The full Plezy feature list (playback, DVR, Explore, Watch Together, and more) lives in the [upstream README](https://github.com/edde746/plezy#readme). Anything listed there is Plezy's work, not PlezTV's.

## Install

PlezTV is **not on any app store** — no Google Play, App Store, F-Droid, or Amazon listing exists, and there is nothing to download from a store.

- **Android:** APKs are built from this repo with Codemagic (the Android Debug workflow) and shared directly. No GitHub Releases have been published for this repo yet.
- PlezTV installs alongside the original Plezy (package `com.matt.plezytv`), so your Plezy install is untouched.

## Building

Prerequisites: Flutter SDK 3.47.0+, and Java 17 for the Android build. Android builds run on Codemagic — see [codemagic.yaml](codemagic.yaml).

```bash
git clone https://github.com/cartchai/plezy-tv.git
cd plezy-tv
flutter pub get
scripts/codegen.sh
flutter build apk --debug
```

After modifying model classes or other generated sources, re-run `scripts/codegen.sh`. After modifying translations, run `dart run slang`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, formatting, tests, and translation guidelines.

## License

PlezTV is licensed under [GPL-3.0](LICENSE), the same as upstream Plezy. This fork stays GPL-3.0.

## Acknowledgments

- Based on [Plezy](https://github.com/edde746/plezy) by edde746 and contributors.
- Built with [Flutter](https://flutter.dev). Playback powered by [mpv](https://mpv.io), Android [ExoPlayer](https://developer.android.com/media/media3/exoplayer), and [libass](https://github.com/peerless2012/libass-android).
