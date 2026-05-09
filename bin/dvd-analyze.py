#!/usr/bin/env python3
"""
dvd-analyze.py — Pre-rip DVD title analysis for TV show discs.

Parses makemkvcon --robot info output to:
1. Detect and exclude "play all" concatenated titles
2. Determine correct episode ordering
3. Output title indices to rip

Usage:
    # From disc (runs makemkvcon internally)
    python3 dvd-analyze.py

    # From saved scan output
    python3 dvd-analyze.py /tmp/disc_info.txt

    # Machine-readable output for piping to rip script
    python3 dvd-analyze.py --json
    python3 dvd-analyze.py --titles-only    # just print title indices to rip

Exit codes:
    0 = success (titles found)
    1 = no disc / no titles
    2 = scan error
"""

import sys
import re
import json
import subprocess
import collections
import os

MAKEMKVCON = "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"
MIN_TV_SECONDS = 1200  # 20 minutes — minimum for a real TV episode


def scan_disc():
    """Run makemkvcon -r info disc:0 and return raw output."""
    try:
        result = subprocess.run(
            [MAKEMKVCON, "-r", "info", "disc:0"],
            capture_output=True, text=True, timeout=120
        )
        return result.stdout
    except FileNotFoundError:
        print("ERROR: makemkvcon not found at", MAKEMKVCON, file=sys.stderr)
        sys.exit(2)
    except subprocess.TimeoutExpired:
        print("ERROR: disc scan timed out after 120s", file=sys.stderr)
        sys.exit(2)


def parse_duration(s):
    """Convert H:MM:SS to seconds."""
    parts = s.split(":")
    try:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except (ValueError, IndexError):
        return 0


def parse_tinfo(raw_output):
    """Parse TINFO lines into per-title dicts."""
    titles = collections.defaultdict(lambda: {
        "chapters": 0,
        "secs": 0,
        "duration": "0:00:00",
        "segments": set(),
        "segments_raw": "",
        "size_bytes": 0,
        "filename": "",
        "name": "",
    })

    disc_name = ""

    for line in raw_output.splitlines():
        # Disc volume label
        m = re.match(r'^CINFO:2,0,"(.*)"$', line)
        if m:
            disc_name = m.group(1)
            continue

        # Title info
        m = re.match(r'^TINFO:(\d+),(\d+),(\d+),"(.*)"$', line)
        if not m:
            continue

        tid = int(m.group(1))
        attr = int(m.group(2))
        val = m.group(4)

        if attr == 2:    # name
            titles[tid]["name"] = val
        elif attr == 8:  # chapter count
            try:
                titles[tid]["chapters"] = int(val)
            except ValueError:
                pass
        elif attr == 9:  # duration
            titles[tid]["duration"] = val
            titles[tid]["secs"] = parse_duration(val)
        elif attr == 11: # size bytes
            try:
                titles[tid]["size_bytes"] = int(val)
            except ValueError:
                pass
        elif attr == 16: # segment map
            titles[tid]["segments_raw"] = val
            if val:
                titles[tid]["segments"] = set(
                    s.strip() for s in val.split(",") if s.strip()
                )
        elif attr == 27: # output filename
            titles[tid]["filename"] = val

    return dict(titles), disc_name


def detect_play_all(titles):
    """
    Identify a play-all title by structural signals. Returns (play_all_id, score, reason).

    Primary rule: the longest title is the play-all only if it's dramatically
    longer than the second-longest AND its duration is roughly the sum of the
    other long titles. Real play-alls concatenate 3+ episodes — margin is always
    high. A single bonus feature that's merely longer than episodes will fail
    the duration-share check.

    Confirming signal: candidate's chapter count ≈ sum of other titles' chapters
    (most discs concatenate chapters). When present, allows a lower margin.

    Replaces the prior chapter-count==n_others heuristic which falsely flagged
    episodes whose chapter count happened to equal the count of other long
    titles — a real bug seen on Baa Baa Black Sheep S1 D1.
    """
    long = {tid: t for tid, t in titles.items() if t["secs"] >= MIN_TV_SECONDS}

    if len(long) < 3:
        return None, 0, "fewer than 3 titles over 20min"

    by_dur = sorted(long.items(), key=lambda kv: kv[1]["secs"], reverse=True)
    cand_tid, cand = by_dur[0]
    second_secs = by_dur[1][1]["secs"]

    margin = cand["secs"] / second_secs if second_secs > 0 else 0
    others_sum = sum(t["secs"] for tid, t in long.items() if tid != cand_tid)
    share = cand["secs"] / others_sum if others_sum > 0 else 0

    cand_chaps = cand["chapters"]
    others_chap_sum = sum(t["chapters"] for tid, t in long.items() if tid != cand_tid)
    chap_match = cand_chaps >= 2 and others_chap_sum >= 2 and abs(cand_chaps - others_chap_sum) <= 2

    if margin >= 2.5 and 0.70 <= share <= 1.40:
        score = int(margin * 10) + int(share * 30)
        if chap_match:
            score += 20
        reason = f"longest {margin:.1f}x second-longest; duration {share:.2f}x sum of others"
        if chap_match:
            reason += f"; chapters {cand_chaps}≈{others_chap_sum}"
        return cand_tid, score, reason

    if chap_match and margin >= 1.8 and 0.50 <= share <= 1.60:
        score = 50 + int(margin * 5)
        return cand_tid, score, f"chapter sum match ({cand_chaps}≈{others_chap_sum}); margin {margin:.1f}x; share {share:.2f}"

    return None, 0, f"no play-all (longest {margin:.2f}x second; share {share:.2f}; chap_match={chap_match})"


def get_episode_titles(titles, play_all_id):
    """
    Return episode titles in correct order (by title ID = IFO PGC order).
    Excludes play-all and short extras (<33% of median episode duration).
    """
    # Exclude play-all
    candidates = {
        tid: t for tid, t in titles.items()
        if tid != play_all_id and t["secs"] >= MIN_TV_SECONDS
    }

    if not candidates:
        return []

    # Compute median duration
    durations = sorted(t["secs"] for t in candidates.values())
    median = durations[len(durations) // 2]

    # Filter out short extras (<33% of median)
    episodes = []
    for tid in sorted(candidates.keys()):
        t = candidates[tid]
        if median > 0 and t["secs"] < median // 3:
            continue
        episodes.append({"id": tid, **t})

    return episodes


def format_duration(secs):
    """Format seconds as H:MM:SS."""
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    return f"{h}:{m:02d}:{s:02d}"


def main():
    args = sys.argv[1:]
    json_mode = "--json" in args
    titles_only = "--titles-only" in args
    args = [a for a in args if not a.startswith("--")]

    # Get disc info from file or live scan
    if args and os.path.isfile(args[0]):
        with open(args[0]) as f:
            raw = f.read()
    else:
        if not json_mode and not titles_only:
            print("Scanning disc...")
        raw = scan_disc()

    titles, disc_name = parse_tinfo(raw)

    if not titles:
        if json_mode:
            print(json.dumps({"error": "no titles found", "disc": disc_name}))
        else:
            print("No titles found. Is a disc inserted?")
        sys.exit(1)

    # Detect play-all
    play_all_id, score, reason = detect_play_all(titles)

    # Get episodes
    episodes = get_episode_titles(titles, play_all_id)

    if json_mode:
        result = {
            "disc_name": disc_name,
            "total_titles": len(titles),
            "play_all": {
                "title_id": play_all_id,
                "score": score,
                "reason": reason,
                "duration": titles[play_all_id]["duration"] if play_all_id is not None else None,
                "chapters": titles[play_all_id]["chapters"] if play_all_id is not None else None,
            } if play_all_id is not None else None,
            "episodes": [
                {
                    "title_id": ep["id"],
                    "duration": ep["duration"],
                    "chapters": ep["chapters"],
                    "segments": ep["segments_raw"],
                }
                for ep in episodes
            ],
            "episode_title_ids": [ep["id"] for ep in episodes],
        }
        print(json.dumps(result))
        sys.exit(0)

    if titles_only:
        # Machine-readable: just print space-separated title IDs
        print(" ".join(str(ep["id"]) for ep in episodes))
        sys.exit(0)

    # Human-readable output
    print(f"\nDisc: {disc_name}")
    print(f"Total titles: {len(titles)}")
    print()

    # All titles table
    print(f"{'ID':>4}  {'Duration':>10}  {'Chap':>4}  {'Segments':<20}  {'Status'}")
    print("-" * 70)
    for tid in sorted(titles.keys()):
        t = titles[tid]
        segs = t["segments_raw"] or "?"
        if len(segs) > 18:
            segs = segs[:15] + "..."
        status = ""
        if tid == play_all_id:
            status = f"← PLAY-ALL (score={score})"
        elif t["secs"] < MIN_TV_SECONDS:
            status = "← short (extra/menu)"
        else:
            ep_idx = next(
                (i for i, ep in enumerate(episodes) if ep["id"] == tid),
                None
            )
            if ep_idx is not None:
                status = f"← Episode {ep_idx + 1}"
        print(
            f"{tid:>4}  {t['duration']:>10}  {t['chapters']:>4}  "
            f"{segs:<20}  {status}"
        )

    print()

    if play_all_id is not None:
        print(f"Play-all: title {play_all_id} — {reason}")
    else:
        print(f"No play-all detected ({reason})")

    print(f"\nEpisodes to rip ({len(episodes)}):")
    for i, ep in enumerate(episodes, 1):
        print(f"  E{i:02d}: title {ep['id']} — {ep['duration']} ({ep['chapters']} chapters)")

    print(f"\nTitle IDs: {' '.join(str(ep['id']) for ep in episodes)}")


if __name__ == "__main__":
    main()
