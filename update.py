#!/usr/bin/env python3
"""Roblox Studio MCP Bridge Auto-Updater Wizard.

Downloads the latest installer script from GitHub releases and runs it,
so users always get the newest setup wizard behavior.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib import error as urlerror
from urllib import request as urlrequest

DEFAULT_REPO = os.environ.get("GITHUB_REPOSITORY", "eyedautumn/python_roblox_studio_mcp")


def _print(msg: str) -> None:
    print(msg, flush=True)


def _fetch_latest_release(repo: str) -> dict:
    api_url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urlrequest.Request(
        api_url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "roblox-mcp-auto-updater",
        },
    )
    with urlrequest.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _download(url: str, destination: Path) -> None:
    req = urlrequest.Request(url, headers={"User-Agent": "roblox-mcp-auto-updater"})
    with urlrequest.urlopen(req, timeout=30) as resp, destination.open("wb") as out:
        out.write(resp.read())


def _resolve_install_script_url(repo: str, release: dict) -> tuple[str, str]:
    assets = release.get("assets") or []
    for asset in assets:
        if asset.get("name") == "install.py" and asset.get("browser_download_url"):
            return asset["browser_download_url"], asset.get("name", "install.py")

    tag = release.get("tag_name")
    if not tag:
        raise RuntimeError("Could not find install.py in release assets and tag_name is missing.")

    raw_url = f"https://raw.githubusercontent.com/{repo}/{tag}/install.py"
    return raw_url, "install.py"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Download and run the latest Roblox MCP installer wizard."
    )
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub repo slug, e.g. owner/repo")
    parser.add_argument(
        "installer_args",
        nargs=argparse.REMAINDER,
        help="Arguments passed through to install.py (prefix with --).",
    )
    args = parser.parse_args()

    _print("\nRoblox Studio MCP Bridge — Auto-Updater Wizard")
    _print("------------------------------------------------")
    _print(f"Repository: {args.repo}")

    try:
        release = _fetch_latest_release(args.repo)
        version = release.get("tag_name") or "<unknown>"
        _print(f"Latest release: {version}")

        url, filename = _resolve_install_script_url(args.repo, release)
        temp_dir = Path(tempfile.mkdtemp(prefix="roblox-mcp-updater-"))
        script_path = temp_dir / filename

        _print(f"Downloading installer from: {url}")
        _download(url, script_path)

        cmd = [sys.executable, str(script_path)]
        pass_through = list(args.installer_args or [])
        if pass_through and pass_through[0] == "--":
            pass_through = pass_through[1:]
        cmd.extend(pass_through)

        _print("Launching latest installer wizard...\n")
        return subprocess.call(cmd)
    except (urlerror.URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as exc:
        _print(f"ERROR: Auto-update failed: {exc}")
        _print("Tip: check network access and verify the repo slug with --repo owner/repo")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
