"""
Shared fixtures for Media Hub Playwright e2e tests.
"""
import os
import json
import subprocess
import pytest

JELLYFIN_HOST = os.environ.get("JELLYFIN_HOST", "http://localhost:8096")
JELLYFIN_TOKEN = ""

# Read token from file
token_file = os.path.expanduser("~/.jellyfin_token")
if os.path.exists(token_file):
    with open(token_file) as f:
        JELLYFIN_TOKEN = f.read().strip()


@pytest.fixture(scope="session")
def jellyfin_host():
    return JELLYFIN_HOST


@pytest.fixture(scope="session")
def jellyfin_token():
    return JELLYFIN_TOKEN


@pytest.fixture(scope="session")
def jellyfin_auth_header():
    return (
        f'MediaBrowser Client="e2e-tests", Device="Mac", '
        f'DeviceId="e2e-test-01", Version="1.0", Token="{JELLYFIN_TOKEN}"'
    )


@pytest.fixture(scope="session")
def api_url():
    """Base URL for API calls."""
    return JELLYFIN_HOST


@pytest.fixture(scope="session")
def media_root():
    return "/Volumes/M4Drive/media"
