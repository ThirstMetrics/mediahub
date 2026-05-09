"""
Smoke tests — verify Jellyfin is running and the media pipeline is functional.
Run: cd ~/.mediahub/tests && python3 -m pytest test_smoke.py -v
"""
import os
import json
import subprocess
import requests
import pytest


class TestJellyfinAlive:
    """Verify Jellyfin server is accessible and responding."""

    def test_jellyfin_responds(self, jellyfin_host):
        """Jellyfin HTTP server responds on port 8096."""
        resp = requests.get(f"{jellyfin_host}/System/Info/Public", timeout=10)
        assert resp.status_code == 200
        data = resp.json()
        assert "ServerName" in data
        assert "Version" in data

    def test_jellyfin_api_auth(self, jellyfin_host, jellyfin_auth_header):
        """API token authenticates successfully."""
        resp = requests.get(
            f"{jellyfin_host}/System/Info",
            headers={"Authorization": jellyfin_auth_header},
            timeout=10,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data.get("OperatingSystemDisplayName") is not None

    def test_jellyfin_libraries_exist(self, jellyfin_host, jellyfin_auth_header):
        """At least one media library is configured."""
        resp = requests.get(
            f"{jellyfin_host}/Library/VirtualFolders",
            headers={"Authorization": jellyfin_auth_header},
            timeout=10,
        )
        assert resp.status_code == 200
        libraries = resp.json()
        assert len(libraries) > 0, "No media libraries configured"
        lib_names = [lib["Name"] for lib in libraries]
        assert any(
            name.lower() in ("movies", "tv shows", "tv", "music")
            for name in lib_names
        ), f"Expected media library not found in {lib_names}"


class TestMediaPipelineTools:
    """Verify ripping tools are installed and accessible."""

    def test_makemkv_installed(self):
        """MakeMKV binary exists and is executable."""
        path = "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon"
        assert os.path.isfile(path), f"MakeMKV not found at {path}"
        assert os.access(path, os.X_OK), f"MakeMKV not executable"

    def test_handbrake_installed(self):
        """HandBrakeCLI binary exists."""
        path = os.path.expanduser("~/bin/HandBrakeCLI")
        assert os.path.isfile(path), f"HandBrakeCLI not found at {path}"
        assert os.access(path, os.X_OK)

    def test_ffmpeg_installed(self):
        """ffmpeg binary exists."""
        path = os.path.expanduser("~/bin/ffmpeg")
        assert os.path.isfile(path), f"ffmpeg not found at {path}"
        assert os.access(path, os.X_OK)

    def test_rip_script_exists(self):
        """Main rip script exists and is executable."""
        path = os.path.expanduser("~/bin/rip")
        assert os.path.isfile(path), f"rip script not found at {path}"
        assert os.access(path, os.X_OK)

    def test_dvd_analyze_exists(self):
        """dvd-analyze.py script exists."""
        path = os.path.expanduser("~/bin/dvd-analyze.py")
        assert os.path.isfile(path)

    def test_jellyfin_api_helper_exists(self):
        """jellyfin-api helper exists and is executable."""
        path = os.path.expanduser("~/bin/jellyfin-api")
        assert os.path.isfile(path)
        assert os.access(path, os.X_OK)

    def test_disc_watcher_exists(self):
        """discwatcher.sh exists."""
        path = os.path.expanduser("~/bin/discwatcher.sh")
        assert os.path.isfile(path)


class TestMediaDirectories:
    """Verify media directory structure exists."""

    def test_m4drive_mounted(self, media_root):
        """M4Drive is mounted at /Volumes/M4Drive."""
        # This test will fail if M4Drive is not mounted — that's intentional
        assert os.path.isdir("/Volumes/M4Drive"), "M4Drive not mounted"

    def test_media_root_exists(self, media_root):
        """Media root directory exists."""
        if not os.path.isdir("/Volumes/M4Drive"):
            pytest.skip("M4Drive not mounted")
        assert os.path.isdir(media_root)

    def test_movies_dir_exists(self, media_root):
        """Movies directory exists."""
        if not os.path.isdir("/Volumes/M4Drive"):
            pytest.skip("M4Drive not mounted")
        assert os.path.isdir(os.path.join(media_root, "movies"))

    def test_tvshows_dir_exists(self, media_root):
        """TV Shows directory exists."""
        if not os.path.isdir("/Volumes/M4Drive"):
            pytest.skip("M4Drive not mounted")
        assert os.path.isdir(os.path.join(media_root, "tvshows"))

    def test_state_dir_exists(self):
        """Episode counter state directory exists."""
        path = os.path.expanduser("~/.mediahub/state")
        assert os.path.isdir(path)
