# MediaHub

DVD/BD ripping pipeline for the home Jellyfin server: MakeMKV → HandBrake → TMDB metadata → Jellyfin folder layout. Plus the cross-machine git/Nextcloud hygiene helpers (`away`, `back`, `save-all`) and bandwidth telemetry (`nethog`, `bandwidth-*`).

Lives at `~/Mediahub/` on every Mac. The `~/bin/<name>` paths the launchd plists reference are symlinks pointing here, so the legacy paths keep working unchanged.

## Layout

- `bin/` — pipeline + helper scripts (`rip`, `discwatcher.sh`, `dvd-analyze.py`, `dvd-killer.sh`, `jellyfin-api`, `tv-match.py`, `ripcd`, `ripstatus`, `download-server.py`, `away`, `back`, `save-all`, `git-audit.sh`, `nc-sync.sh`, `nethog*`, `bandwidth-*`, `tmain`)
- `launchd/` — agent plists for `com.mediahub.discwatcher`, `com.mediahub.dvdkiller`, `com.mediahub.download-server`. Copy to `~/Library/LaunchAgents/` and `launchctl bootstrap` on hosts that should auto-rip.
- `tests/` — pytest suite (smoke, dvd_analyze, jellyfin UI)
- `docs/` — handoff notes

## Bootstrap on a new Mac (MacBook Air, etc.)

```sh
# 1. Clone
git clone https://github.com/thirstmetrics/mediahub.git ~/Mediahub

# 2. Symlink scripts into ~/bin so legacy paths resolve
mkdir -p ~/bin
for f in ~/Mediahub/bin/*; do
  name="$(basename "$f")"
  [[ -e "$HOME/bin/$name" ]] || ln -s "$f" "$HOME/bin/$name"
done

# 3. Install heavy tooling (these stay in ~/bin, not in the repo — too large)
brew install handbrake ffmpeg
ln -s "$(which HandBrakeCLI)" ~/bin/HandBrakeCLI
ln -s "$(which ffprobe)"     ~/bin/ffprobe
ln -s "$(which ffmpeg)"      ~/bin/ffmpeg

# 4. MakeMKV — drag from https://www.makemkv.com to /Applications

# 5. State + log dirs
mkdir -p ~/.mediahub/state ~/.mediahub/logs

# 6. Optional — install launchd agents for fire-and-forget auto-rip on disc insert
cp ~/Mediahub/launchd/com.mediahub.{discwatcher,dvdkiller}.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mediahub.discwatcher.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mediahub.dvdkiller.plist

# 7. Optional — disable macOS DVD Player autoplay (recipe near bottom of this README)
```

## External dependencies (paths the scripts assume)

- `/Applications/MakeMKV.app/Contents/MacOS/makemkvcon`
- `~/bin/HandBrakeCLI`
- `~/bin/ffprobe` (also falls back to `/Applications/Jellyfin.app/Contents/MacOS/ffprobe` if missing)
- Python 3.9+ for the analyzer and tests

## MEDIA_ROOT

`bin/rip` writes to `/Volumes/M4Drive/media`. On a machine without that volume, either:
- Rename your scratch USB drive to `M4Drive` in Disk Utility, or
- Edit `MEDIA_ROOT` at the top of `bin/rip`.

## Quality

`bin/rip` defaults to **HandBrake CRF 14** (~3-4 GB / movie, near-disc quality). Per-disc dialog lets you toggle to **Standard CRF 20** (~1 GB) for sources where the smaller file is fine. DVDs are 480p source — true 1080p requires Blu-ray source discs.

## Cross-machine workflow

- `~/bin/away` — end of day: `save-all` allowlisted repos, refresh `git-state.md` to Nextcloud, sync, quit Chrome/OneDrive/Docker, optional `pmset` Power Nap off + overnight bandwidth capture.
- `~/bin/back` — start of day: stop overnight capture, `nc-sync` pull, `git fetch + ff-pull` every clean repo with an upstream that's behind, refresh + sync `git-state.md`, reopen Chrome.
- `git-state.md` per machine syncs through `~/Nextcloud/_machines/<host>/` so all hosts can eyeball each other's state at a glance.

## DVD Player autoplay disable (macOS Sequoia+)

```sh
defaults write com.apple.digihub com.apple.digihub.dvd.video-inserted '{ "action" = 1; }'
defaults write com.apple.digihub com.apple.digihub.bd.video-inserted '{ "action" = 1; }'
killall cfprefsd
launchctl disable gui/$(id -u)/application.com.apple.DVDPlayer
launchctl disable gui/$(id -u)/com.apple.DVDPlayer
```

`com.mediahub.dvdkiller` is the belt-and-suspenders kill-on-sight watcher for cases where Launch Services bypasses the above (does on Sequoia even with all four set).

## Recovering from drive lockup

Symptom: MakeMKV hits "OS X IPC Error" + "Device not configured" → optical drive's USB controller hangs; `system_profiler SPUSBDataType` no longer shows the Matshita BD-MLT. Fix:
1. Unplug drive USB, wait 10 s, replug.
2. If it doesn't re-enumerate, try a different USB port or reboot.
3. Clean disc, retry. If the same byte offset fails twice, the disc has physical damage — Override the title in the analyzer dialog or get a replacement.

## Counter files

TV episode counters at `~/.mediahub/state/<Show>_S<XX>.ep`. When ripping the same show across multiple machines, manually `echo N > ~/.mediahub/state/<Show>_S<XX>.ep` on the destination before continuing, so episodes don't collide.
