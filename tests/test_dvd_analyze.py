"""
Unit tests for dvd-analyze.py — play-all detection and episode ordering.
Run: cd ~/.mediahub/tests && python3 -m pytest test_dvd_analyze.py -v

Tests use synthetic TINFO data to verify the multi-signal play-all detection
works across different disc scenarios.
"""
import os
import sys
import json
import tempfile
import subprocess
import pytest

DVD_ANALYZE = os.path.expanduser("~/bin/dvd-analyze.py")


def make_tinfo(titles):
    """
    Generate synthetic MakeMKV robot-mode TINFO output.

    titles: list of dicts with keys:
        id: int (title index)
        duration: str "H:MM:SS"
        chapters: int
        segments: str (comma-separated segment IDs)
    """
    lines = ['CINFO:2,0,"TEST_DISC"']
    for t in titles:
        tid = t["id"]
        lines.append(f'TINFO:{tid},2,0,"Title {tid}"')
        lines.append(f'TINFO:{tid},8,0,"{t.get("chapters", 1)}"')
        lines.append(f'TINFO:{tid},9,0,"{t["duration"]}"')
        lines.append(f'TINFO:{tid},11,0,"{t.get("size", 1000000000)}"')
        segs = t.get("segments", str(tid + 1))
        lines.append(f'TINFO:{tid},16,0,"{segs}"')
        lines.append(f'TINFO:{tid},27,0,"title_t{tid:02d}.mkv"')
    return "\n".join(lines)


def run_analyze(tinfo_content, extra_args=None):
    """Write TINFO to temp file and run dvd-analyze.py --json."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        f.write(tinfo_content)
        f.flush()
        args = [sys.executable, DVD_ANALYZE, "--json", f.name]
        if extra_args:
            args.extend(extra_args)
        result = subprocess.run(args, capture_output=True, text=True)
        os.unlink(f.name)
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)


class TestPlayAllDetection:
    """Test play-all detection across different disc scenarios."""

    def test_classic_4ep_disc_with_play_all(self):
        """Standard TV disc: 1 play-all (3h22m, 4 chapters) + 4 episodes (~50min, 1 chapter each)."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "3:22:14", "chapters": 4, "segments": "1,2,3,4"},
            {"id": 1, "duration": "0:50:32", "chapters": 1, "segments": "1"},
            {"id": 2, "duration": "0:50:48", "chapters": 1, "segments": "2"},
            {"id": 3, "duration": "0:50:04", "chapters": 1, "segments": "3"},
            {"id": 4, "duration": "0:50:50", "chapters": 1, "segments": "4"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        assert result["play_all"] is not None
        assert result["play_all"]["title_id"] == 0
        assert result["play_all"]["score"] >= 40
        assert len(result["episodes"]) == 4
        assert result["episode_title_ids"] == [1, 2, 3, 4]

    def test_uniform_duration_poirot_style(self):
        """Poirot-style: all episodes ~50min, play-all ~3:22. Duration alone is ambiguous."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "3:22:00", "chapters": 4, "segments": "1,2,3,4"},
            {"id": 1, "duration": "0:50:30", "chapters": 1, "segments": "1"},
            {"id": 2, "duration": "0:50:30", "chapters": 1, "segments": "2"},
            {"id": 3, "duration": "0:50:30", "chapters": 1, "segments": "3"},
            {"id": 4, "duration": "0:50:30", "chapters": 1, "segments": "4"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        assert result["play_all"] is not None
        assert result["play_all"]["title_id"] == 0
        # Should detect via chapter count AND segment superset even when durations are uniform
        assert result["play_all"]["score"] >= 70
        assert len(result["episodes"]) == 4

    def test_no_play_all_disc(self):
        """Disc with just episodes, no play-all concatenation."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "0:50:32", "chapters": 1, "segments": "1"},
            {"id": 1, "duration": "0:50:48", "chapters": 1, "segments": "2"},
            {"id": 2, "duration": "0:50:04", "chapters": 1, "segments": "3"},
            {"id": 3, "duration": "0:50:50", "chapters": 1, "segments": "4"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        assert result["play_all"] is None
        assert len(result["episodes"]) == 4

    def test_play_all_with_short_extras(self):
        """Disc with play-all + episodes + bonus extras (< 20min)."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "2:05:00", "chapters": 3, "segments": "1,2,3"},
            {"id": 1, "duration": "0:42:10", "chapters": 1, "segments": "1"},
            {"id": 2, "duration": "0:41:50", "chapters": 1, "segments": "2"},
            {"id": 3, "duration": "0:41:00", "chapters": 1, "segments": "3"},
            {"id": 4, "duration": "0:05:30", "chapters": 1, "segments": "5"},  # bonus
            {"id": 5, "duration": "0:03:00", "chapters": 1, "segments": "6"},  # trailer
        ])
        result = run_analyze(tinfo)
        assert result is not None
        assert result["play_all"]["title_id"] == 0
        assert len(result["episodes"]) == 3
        # Short extras should be excluded
        assert 4 not in result["episode_title_ids"]
        assert 5 not in result["episode_title_ids"]

    def test_play_all_with_per_episode_chapters(self):
        """
        Disc where individual episodes ALSO have chapters (e.g., BBC box sets).
        Play-all has chapters = N_episodes × avg_chapters_per_ep.
        """
        tinfo = make_tinfo([
            {"id": 0, "duration": "3:22:00", "chapters": 16, "segments": "1,2,3,4"},
            {"id": 1, "duration": "0:50:30", "chapters": 4, "segments": "1"},
            {"id": 2, "duration": "0:50:30", "chapters": 4, "segments": "2"},
            {"id": 3, "duration": "0:50:30", "chapters": 4, "segments": "3"},
            {"id": 4, "duration": "0:50:30", "chapters": 4, "segments": "4"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        # Segment superset + duration should still detect it
        assert result["play_all"]["title_id"] == 0
        assert len(result["episodes"]) == 4

    def test_no_segments_fallback_to_chapters(self):
        """Older disc without segment map data — detection falls back to chapter count."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "3:22:00", "chapters": 4, "segments": ""},
            {"id": 1, "duration": "0:50:30", "chapters": 1, "segments": ""},
            {"id": 2, "duration": "0:50:30", "chapters": 1, "segments": ""},
            {"id": 3, "duration": "0:50:30", "chapters": 1, "segments": ""},
            {"id": 4, "duration": "0:50:30", "chapters": 1, "segments": ""},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        # Should still detect via chapter count + duration
        assert result["play_all"]["title_id"] == 0
        assert result["play_all"]["score"] >= 40

    def test_two_episode_disc(self):
        """Disc with only 2 episodes — below the 3-title minimum, no play-all detection."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "0:50:30", "chapters": 1, "segments": "1"},
            {"id": 1, "duration": "0:50:30", "chapters": 1, "segments": "2"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        assert result["play_all"] is None
        assert len(result["episodes"]) == 2


class TestEpisodeOrdering:
    """Test that episodes are returned in correct order."""

    def test_episodes_ordered_by_title_id(self):
        """Episodes should be in title ID order (= IFO PGC order)."""
        tinfo = make_tinfo([
            {"id": 0, "duration": "3:22:00", "chapters": 4, "segments": "1,2,3,4"},
            {"id": 3, "duration": "0:50:04", "chapters": 1, "segments": "3"},
            {"id": 1, "duration": "0:50:32", "chapters": 1, "segments": "1"},
            {"id": 4, "duration": "0:50:50", "chapters": 1, "segments": "4"},
            {"id": 2, "duration": "0:50:48", "chapters": 1, "segments": "2"},
        ])
        result = run_analyze(tinfo)
        assert result is not None
        # Should be sorted by title ID regardless of input order
        assert result["episode_title_ids"] == [1, 2, 3, 4]


class TestTitlesOnlyOutput:
    """Test --titles-only flag for piping to rip script."""

    def test_titles_only_output(self):
        tinfo_content = make_tinfo([
            {"id": 0, "duration": "3:22:14", "chapters": 4, "segments": "1,2,3,4"},
            {"id": 1, "duration": "0:50:32", "chapters": 1, "segments": "1"},
            {"id": 2, "duration": "0:50:48", "chapters": 1, "segments": "2"},
            {"id": 3, "duration": "0:50:04", "chapters": 1, "segments": "3"},
            {"id": 4, "duration": "0:50:50", "chapters": 1, "segments": "4"},
        ])
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write(tinfo_content)
            f.flush()
            result = subprocess.run(
                [sys.executable, DVD_ANALYZE, "--titles-only", f.name],
                capture_output=True, text=True,
            )
            os.unlink(f.name)
        assert result.returncode == 0
        # Should output space-separated title IDs
        ids = result.stdout.strip().split()
        assert ids == ["1", "2", "3", "4"]
