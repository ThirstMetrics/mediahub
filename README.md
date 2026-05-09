# MediaHub

DVD ripping pipeline: MakeMKV → HandBrake → TMDB metadata → Jellyfin folder layout.

Snapshot taken from `johns-mac-mini:~/bin/` on 2026-05-09 to enable iteration on a second machine. The Mac Mini retains its working copy untouched; merge changes back from this repo when ready.

## Layout

- `bin/` — pipeline scripts (rip, ripstatus, discwatcher, tv-match, dvd-analyze, etc.)
- `tests/` — pytest suite (smoke, dvd_analyze, jellyfin UI)
- `docs/` — handoff notes and known issues

## External dependencies

Install on whichever machine runs the pipeline:

- **MakeMKV** — expected at `/Applications/MakeMKV.app/Contents/MacOS/makemkvcon`
- **HandBrakeCLI** — expected at `~/bin/HandBrakeCLI`
- **ffmpeg** — expected at `~/bin/ffmpeg`
- **Python 3.9+** with `pytest` for the test suite
- **MEDIA_ROOT** — `rip` writes to `/Volumes/M4Drive/media`. Override the constant in `bin/rip` if iterating on a machine without that drive.

## Latest handoff

See `docs/2026-04-19-handoff.md` for the current state of TV episode handling, Poirot folder consolidation, and known issues (counter-file naming with year, broken `ripcd`).
