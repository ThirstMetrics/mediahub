#!/usr/bin/env python3
"""
tv-match.py — Match MakeMKV-ripped MKV files to TVDB episodes by runtime.

Usage:
    tv-match.py "Show Name" SEASON RAW_DIR

Reads all *.mkv files in RAW_DIR, computes their durations with ffprobe,
queries TMDB for the show's season episode list, and matches each MKV to
an episode by runtime within ±15%. Prints rename commands to stdout.

Output format (one per line):
    SOURCE_PATH|EPISODE_NUM|EPISODE_TITLE
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

TMDB_KEY = "8265bd1679663a7ea12ac168da84d2e8"
TOLERANCE = 0.15  # ±15% runtime tolerance


def tmdb_get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)
    except Exception as e:
        print(f"# TMDB error: {e}", file=sys.stderr)
        return None


def find_show(name):
    q = urllib.parse.quote(name)
    data = tmdb_get(f"https://api.themoviedb.org/3/search/tv?api_key={TMDB_KEY}&query={q}")
    if not data or not data.get("results"):
        return None
    return data["results"][0]


def get_episodes(show_id, season):
    data = tmdb_get(f"https://api.themoviedb.org/3/tv/{show_id}/season/{season}?api_key={TMDB_KEY}")
    if not data:
        return []
    return data.get("episodes", [])


def mkv_duration(path):
    """Return duration in seconds by parsing ffmpeg -i output."""
    import re
    try:
        proc = subprocess.run(
            [os.path.expanduser("~/bin/ffmpeg"), "-i", path],
            capture_output=True,
        )
        text = proc.stderr.decode("utf-8", errors="replace")
        m = re.search(r"Duration:\s+(\d+):(\d+):(\d+\.\d+)", text)
        if m:
            h, mn, s = m.groups()
            return int(h) * 3600 + int(mn) * 60 + float(s)
    except Exception:
        pass
    return 0


def main():
    if len(sys.argv) < 4:
        print("Usage: tv-match.py SHOW SEASON RAW_DIR", file=sys.stderr)
        sys.exit(1)
    show_name = sys.argv[1]
    season = int(sys.argv[2])
    raw_dir = sys.argv[3]

    # Find show on TMDB
    show = find_show(show_name)
    if not show:
        print(f"# No TMDB match for '{show_name}'", file=sys.stderr)
        sys.exit(2)
    print(f"# TMDB show: {show['name']} (id={show['id']})", file=sys.stderr)

    # Get episode list
    episodes = get_episodes(show["id"], season)
    if not episodes:
        print(f"# No episodes for season {season}", file=sys.stderr)
        sys.exit(3)
    print(f"# Found {len(episodes)} episodes for season {season}", file=sys.stderr)

    # Get MKV files with their durations (in seconds)
    mkvs = []
    for fn in sorted(os.listdir(raw_dir)):
        if fn.endswith(".mkv") and not fn.startswith("._"):
            path = os.path.join(raw_dir, fn)
            dur = mkv_duration(path)
            if dur > 60:  # skip < 1 minute clips
                mkvs.append((path, dur))
                print(f"# MKV: {fn} = {dur:.0f}s ({dur/60:.1f}min)", file=sys.stderr)

    # Check if runtimes vary enough for reliable matching
    runtimes = [ep.get("runtime", 0) for ep in episodes if ep.get("runtime")]
    if runtimes:
        avg_rt = sum(runtimes) / len(runtimes)
        variance = max(runtimes) - min(runtimes)
        if avg_rt > 0 and variance / avg_rt < 0.15:
            print(f"# Runtime variance too low ({variance}min spread on {avg_rt:.0f}min avg) — sequential numbering recommended", file=sys.stderr)
            sys.exit(0)  # Empty output = rip script falls back to sequential

    # Match each MKV to the closest episode by runtime
    used_episodes = set()
    for path, dur in mkvs:
        best_ep = None
        best_diff = None
        for ep in episodes:
            ep_num = ep["episode_number"]
            if ep_num in used_episodes:
                continue
            ep_runtime = ep.get("runtime") or 0
            if ep_runtime <= 0:
                continue
            ep_secs = ep_runtime * 60
            diff = abs(dur - ep_secs) / ep_secs
            if diff <= TOLERANCE and (best_diff is None or diff < best_diff):
                best_ep = ep
                best_diff = diff
        if best_ep:
            used_episodes.add(best_ep["episode_number"])
            title = best_ep["name"]
            # Sanitize title for filename
            safe_title = title.replace("/", "-").replace(":", " -")
            print(f"{path}|{best_ep['episode_number']}|{safe_title}")
            print(f"# matched: {os.path.basename(path)} -> S{season:02d}E{best_ep['episode_number']:02d} {title} (diff {best_diff*100:.1f}%)", file=sys.stderr)
        else:
            print(f"# UNMATCHED: {os.path.basename(path)} ({dur/60:.1f}min)", file=sys.stderr)


if __name__ == "__main__":
    main()
