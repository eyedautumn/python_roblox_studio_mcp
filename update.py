#!/usr/bin/env python3
"""Roblox Studio MCP Bridge Auto-Updater Wizard.

Downloads the latest installer script from GitHub releases and runs it,
so users always get the newest setup wizard behaviour.

All flags are forwarded to the downloaded install.py, including the new
--server-path flag which controls where the MCP server script is placed.
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
        description="Download and run the latest Roblox MCP installer wizard.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  # Fully interactive — always pulls the newest wizard first
  python update.py

  # Install server to a custom path, register with Claude Code non-interactively
  python update.py \\
      --server-path /opt/roblox-mcp/roblox_mcp_server.py \\
      -- --non-interactive --agent claude-code

  # Update only the server script, skip everything else
  python update.py \\
      --server-path ~/roblox-mcp/roblox_mcp_server.py \\
      -- --non-interactive --skip-skill --skip-plugin --skip-mcp
""",
    )
    parser.add_argument("--repo", default=DEFAULT_REPO,
                        help="GitHub repo slug, e.g. owner/repo")

    # ── Flags mirrored from install.py so they can be set at the update.py
    #    level (no need to use the -- pass-through for the common cases).
    parser.add_argument(
        "--server-path",
        default=None,
        help=(
            "Where to install / update roblox_mcp_server.py. "
            "Forwarded to install.py as --server-path. "
            "Defaults to a platform-appropriate location if omitted."
        ),
    )
    # Keep old name as a silent alias
    parser.add_argument("--server-script", default=None, help=argparse.SUPPRESS)
    parser.add_argument(
        "--claude-desktop-config",
        default=None,
        help="Optional Claude Desktop config JSON path forwarded to install.py.",
    )
    parser.add_argument(
        "installer_args",
        nargs=argparse.REMAINDER,
        help="Extra arguments passed directly to install.py (prefix with --).",
    )
    args = parser.parse_args()

    # Backwards compat: --server-script → --server-path
    if args.server_script and not args.server_path:
        args.server_path = args.server_script

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

        # Build the command to forward to install.py
        cmd = [sys.executable, str(script_path)]

        # Pass-through args (strip leading "--" sentinel if present)
        pass_through = list(args.installer_args or [])
        if pass_through and pass_through[0] == "--":
            pass_through = pass_through[1:]

        # Inject our top-level flags only if they weren't already supplied in
        # the pass-through block, to avoid duplicates.
        if args.server_path and "--server-path" not in pass_through and "--server-script" not in pass_through:
            cmd.extend(["--server-path", args.server_path])
        if args.claude_desktop_config and "--claude-desktop-config" not in pass_through:
            cmd.extend(["--claude-desktop-config", args.claude_desktop_config])

        cmd.extend(pass_through)

        _print("Launching latest installer wizard…\n")
        return subprocess.call(cmd)

    except (urlerror.URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as exc:
        _print(f"ERROR: Auto-update failed: {exc}")
        _print("Tip: check network access and verify the repo slug with --repo owner/repo")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
