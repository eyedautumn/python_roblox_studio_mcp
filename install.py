#!/usr/bin/env python3
"""
Roblox Studio MCP Bridge — Installation Wizard
Supports: Linux (native + Vinegar/Wine), macOS, Windows

What this does (all steps are optional and can be skipped):
  1. Copy the skill folder to a destination of your choice
  2. Install the Studio plugin (auto-detects platform/Vinegar)
  3. Install / update the MCP server script to a path of your choice
  4. Register the MCP server with your AI agent
     (Claude Code, Claude Desktop, OpenAI Codex, OpenCode, or manual JSON)

No git required. Works entirely from this repo directory.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from urllib import error as urlerror
from urllib import request as urlrequest

# ---------------------------------------------------------------------------
# Compatibility shim for tomllib on Python < 3.11
# ---------------------------------------------------------------------------
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # pip install tomli
    except ImportError:
        tomllib = None

try:
    import tomli_w  # pip install tomli-w  (for writing TOML)
except ImportError:
    tomli_w = None

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE_ROOT = getattr(sys, "_MEIPASS", HERE)
SKILL_SRC = os.path.join(BUNDLE_ROOT, "src", "skill")
SERVER_SRC = os.path.join(BUNDLE_ROOT, "src", "server", "roblox_mcp_server.py")
PROJECT_JSON = os.path.join(BUNDLE_ROOT, "default.project.json")
PLUGIN_RBXM = os.path.join(BUNDLE_ROOT, "RobloxMcpBridge.rbxm")
PLUGIN_LUA = os.path.join(BUNDLE_ROOT, "src", "plugin", "init.plugin.luau")
DEFAULT_GITHUB_REPO = os.environ.get("GITHUB_REPOSITORY", "eyedautumn/python_roblox_studio_mcp")

BRIGHT  = "\033[1m"
GREEN   = "\033[32m"
YELLOW  = "\033[33m"
RED     = "\033[31m"
CYAN    = "\033[36m"
RESET   = "\033[0m"

def c(color, text):
    return f"{color}{text}{RESET}" if sys.stdout.isatty() else text

def header(text):
    print(f"\n{c(BRIGHT, '─' * 60)}")
    print(c(CYAN, f"  {text}"))
    print(c(BRIGHT, '─' * 60))

def ok(text):   print(c(GREEN,  f"  ✓  {text}"))
def warn(text): print(c(YELLOW, f"  ⚠  {text}"))
def err(text):  print(c(RED,    f"  ✗  {text}"))
def info(text): print(f"     {text}")

def ask(prompt, default=None):
    suffix = f" [{default}]" if default else ""
    try:
        val = input(f"  {c(BRIGHT, '?')} {prompt}{suffix}: ").strip()
    except (KeyboardInterrupt, EOFError):
        print(); sys.exit(0)
    return val or default or ""

def ask_yn(prompt, default=True):
    tag = "Y/n" if default else "y/N"
    try:
        val = input(f"  {c(BRIGHT, '?')} {prompt} [{tag}]: ").strip().lower()
    except (KeyboardInterrupt, EOFError):
        print(); sys.exit(0)
    if not val:
        return default
    return val.startswith("y")


# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
def detect_platform():
    s = platform.system()
    if s == "Darwin":  return "macos"
    if s == "Windows": return "windows"
    return "linux"

def is_wsl():
    try:
        with open("/proc/version") as f:
            return "microsoft" in f.read().lower()
    except Exception:
        return False

def windows_path_from_wsl(wsl_path):
    r"""Convert a WSL path like /mnt/c/... to C:\..."""
    m = re.match(r"^/mnt/([a-z])(/.*)$", wsl_path)
    if m:
        return m.group(1).upper() + ":" + m.group(2).replace("/", "\\")
    return wsl_path


# ---------------------------------------------------------------------------
# Plugin directory discovery
# ---------------------------------------------------------------------------
def find_plugin_dirs_linux_native():
    candidates = []
    home = os.path.expanduser("~")
    candidates.append(os.path.join(home, ".var", "app", "org.vinegarhq.Sober",
                                   "data", "roblox", "Plugins"))
    candidates.append(os.path.join(home, ".local", "share", "roblox", "Plugins"))
    return [p for p in candidates if os.path.isdir(p)]

def find_plugin_dirs_vinegar():
    dirs = []
    home = os.path.expanduser("~")
    vinegar_roots = [
        os.path.join(home, ".var", "app", "org.vinegarHq.Vinegar"),
        os.path.join(home, ".var", "app", "org.vinegarhq.Vinegar"),
    ]
    for root in vinegar_roots:
        for prefix_sub in [
            os.path.join("data", "prefixes", "studio", "drive_c"),
            os.path.join("data", "vinegar", "prefixes", "studio", "drive_c"),
        ]:
            drive_c = os.path.join(root, prefix_sub)
            if not os.path.isdir(drive_c):
                continue
            users_dir = os.path.join(drive_c, "users")
            if not os.path.isdir(users_dir):
                continue
            for user in os.listdir(users_dir):
                plugins = os.path.join(users_dir, user,
                                       "AppData", "Local", "Roblox", "Plugins")
                if os.path.isdir(plugins):
                    dirs.append(plugins)
    return dirs

def find_plugin_dirs_macos():
    home = os.path.expanduser("~")
    return [p for p in [
        os.path.join(home, "Documents", "Roblox", "Plugins"),
        os.path.join(home, "Library", "Application Support", "Roblox", "Plugins"),
    ] if os.path.isdir(p)]

def find_plugin_dirs_windows():
    local = os.environ.get("LOCALAPPDATA", "")
    if not local:
        local = os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return [p for p in [
        os.path.join(local, "Roblox", "Plugins"),
    ] if os.path.isdir(p)]

def find_plugin_dirs(custom_path=None):
    if custom_path:
        return [os.path.abspath(os.path.expanduser(custom_path))]
    plat = detect_platform()
    wsl = is_wsl()
    found = []
    if plat == "linux" and not wsl:
        found += find_plugin_dirs_vinegar()
        found += find_plugin_dirs_linux_native()
    elif plat == "macos":
        found += find_plugin_dirs_macos()
    elif plat == "windows" or wsl:
        found += find_plugin_dirs_windows()
    return list(dict.fromkeys(found))


# ---------------------------------------------------------------------------
# Skill copy
# ---------------------------------------------------------------------------
def install_skill(dest):
    if os.path.isdir(dest):
        if not ask_yn(f"  '{dest}' already exists. Overwrite?", default=False):
            warn("Skipped skill installation.")
            return False
        shutil.rmtree(dest)
    shutil.copytree(SKILL_SRC, dest)
    ok(f"Skill installed → {dest}")
    return True


def download_release_plugin_rbxm(repo_slug=None):
    repo = repo_slug or os.environ.get("ROBLOX_MCP_REPO", DEFAULT_GITHUB_REPO)
    api_url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urlrequest.Request(api_url, headers={"Accept": "application/vnd.github+json", "User-Agent": "roblox-mcp-installer"})
    try:
        with urlrequest.urlopen(req, timeout=15) as resp:
            release = json.loads(resp.read().decode("utf-8"))
    except (urlerror.URLError, TimeoutError, json.JSONDecodeError) as exc:
        warn(f"Could not query latest GitHub release for plugin .rbxm ({repo}).")
        info(str(exc))
        return None
    assets = release.get("assets") or []
    asset = next((a for a in assets if a.get("name") == "RobloxMcpBridge.rbxm"), None)
    if not asset:
        warn("Latest GitHub release does not include RobloxMcpBridge.rbxm.")
        return None
    download_url = asset.get("browser_download_url")
    if not download_url:
        warn("Release asset found, but download URL is missing.")
        return None
    fd, temp_path = tempfile.mkstemp(prefix="RobloxMcpBridge-", suffix=".rbxm")
    os.close(fd)
    try:
        req = urlrequest.Request(download_url, headers={"User-Agent": "roblox-mcp-installer"})
        with urlrequest.urlopen(req, timeout=30) as resp, open(temp_path, "wb") as out:
            shutil.copyfileobj(resp, out)
    except (urlerror.URLError, TimeoutError, OSError) as exc:
        warn("Failed downloading RobloxMcpBridge.rbxm from GitHub release.")
        info(str(exc))
        try:
            os.remove(temp_path)
        except OSError:
            pass
        return None
    info(f"Downloaded release plugin .rbxm from {repo}.")
    return temp_path


def _get_latest_release_tag(repo_slug):
    api_url = f"https://api.github.com/repos/{repo_slug}/releases/latest"
    req = urlrequest.Request(
        api_url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "roblox-mcp-installer",
        },
    )
    with urlrequest.urlopen(req, timeout=15) as resp:
        release = json.loads(resp.read().decode("utf-8"))
    tag = release.get("tag_name")
    if not tag:
        raise RuntimeError("latest release tag_name missing")
    return tag


def download_server_script(repo_slug=None):
    repo = repo_slug or os.environ.get("ROBLOX_MCP_REPO", DEFAULT_GITHUB_REPO)
    try:
        tag = _get_latest_release_tag(repo)
    except (urlerror.URLError, TimeoutError, json.JSONDecodeError, RuntimeError) as exc:
        warn(f"Could not resolve latest release tag for MCP server script ({repo}).")
        info(str(exc))
        return None
    raw_url = (
        f"https://raw.githubusercontent.com/{repo}/{tag}/"
        "src/server/roblox_mcp_server.py"
    )
    fd, temp_path = tempfile.mkstemp(prefix="roblox-mcp-server-", suffix=".py")
    os.close(fd)
    try:
        req = urlrequest.Request(raw_url, headers={"User-Agent": "roblox-mcp-installer"})
        with urlrequest.urlopen(req, timeout=30) as resp, open(temp_path, "wb") as out:
            shutil.copyfileobj(resp, out)
    except (urlerror.URLError, TimeoutError, OSError) as exc:
        warn("Failed downloading roblox_mcp_server.py fallback from GitHub.")
        info(str(exc))
        try:
            os.remove(temp_path)
        except OSError:
            pass
        return None
    info(f"Downloaded MCP server script from {repo}@{tag}.")
    return temp_path


# ---------------------------------------------------------------------------
# Plugin installation
# ---------------------------------------------------------------------------
def install_plugin(plugin_dir):
    os.makedirs(plugin_dir, exist_ok=True)
    src = None
    dest = os.path.join(plugin_dir, "RobloxMcpBridge.rbxm")
    if os.path.isfile(PLUGIN_RBXM):
        src = PLUGIN_RBXM
    elif shutil.which("rojo") and os.path.isfile(PROJECT_JSON):
        temp_output = os.path.join(tempfile.gettempdir(), "RobloxMcpBridge.rbxm")
        cmd = ["rojo", "build", PROJECT_JSON, "--output", temp_output]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and os.path.isfile(temp_output):
            src = temp_output
            info("Built RobloxMcpBridge.rbxm locally with rojo.")
        else:
            warn("Could not build .rbxm with rojo.")
            if result.stderr:
                info(result.stderr.strip())
    if not src:
        src = download_release_plugin_rbxm()
    if not src and os.path.isfile(PLUGIN_LUA):
        src = PLUGIN_LUA
        dest = os.path.join(plugin_dir, "RobloxMcpBridge.plugin.lua")
        warn("No .rbxm available — copying raw .luau plugin.")
    if not src:
        err("Cannot find or create plugin file (RobloxMcpBridge.rbxm or init.plugin.luau).")
        return False
    shutil.copy2(src, dest)
    if src.startswith(tempfile.gettempdir() + os.sep) and src.endswith(".rbxm") and src != PLUGIN_RBXM:
        try:
            os.remove(src)
        except OSError:
            pass
    ok(f"Plugin installed → {dest}")
    return True


# ---------------------------------------------------------------------------
# MCP server script install / update
# ---------------------------------------------------------------------------
def default_server_install_path():
    """Return a sensible default install location for the MCP server script."""
    home = os.path.expanduser("~")
    plat = detect_platform()
    if plat == "windows":
        base = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
        return os.path.join(base, "roblox-mcp", "roblox_mcp_server.py")
    if plat == "macos":
        return os.path.join(home, "Library", "Application Support", "roblox-mcp", "roblox_mcp_server.py")
    # Linux / WSL
    return os.path.join(home, ".local", "share", "roblox-mcp", "roblox_mcp_server.py")


def install_server_script(dest_path, force=False):
    """
    Copy / download the MCP server script to dest_path.
    If the file already exists, asks the user whether to overwrite (or overwrites
    silently when force=True).

    Returns the absolute path to the installed script, or None on failure.
    """
    dest_path = os.path.abspath(os.path.expanduser(dest_path))

    if os.path.isfile(dest_path) and not force:
        if not ask_yn(f"  '{dest_path}' already exists. Overwrite / update it?", default=True):
            warn("Kept existing server script.")
            ok(f"Using existing MCP server script → {dest_path}")
            return dest_path

    # Find the source
    source = None
    if os.path.isfile(SERVER_SRC):
        source = SERVER_SRC
    else:
        info("Bundled server script not found — downloading from GitHub…")
        source = download_server_script()

    if not source:
        err("Could not obtain roblox_mcp_server.py (bundle missing and download failed).")
        return None

    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    shutil.copy2(source, dest_path)

    # Clean up temp download
    if source != SERVER_SRC and source.startswith(tempfile.gettempdir() + os.sep):
        try:
            os.remove(source)
        except OSError:
            pass

    action = "Updated" if os.path.isfile(dest_path) else "Installed"
    ok(f"MCP server script {action} → {dest_path}")
    return dest_path


# ---------------------------------------------------------------------------
# MCP server registration helpers
# ---------------------------------------------------------------------------
def python_cmd():
    if sys.executable:
        return os.path.abspath(sys.executable)
    for cmd in ("python3", "python"):
        path = shutil.which(cmd)
        if path:
            return path
    return "python3"

def mcp_server_cmd(server_script_path):
    return [python_cmd(), server_script_path]

# ── Claude Desktop ──────────────────────────────────────────────────────────
def claude_desktop_config_path(custom_path=None):
    if custom_path:
        return os.path.abspath(os.path.expanduser(custom_path))
    plat = detect_platform()
    home = os.path.expanduser("~")
    if plat == "macos":
        return os.path.join(home, "Library", "Application Support",
                            "Claude", "claude_desktop_config.json")
    if plat == "windows":
        appdata = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
        return os.path.join(appdata, "Claude", "claude_desktop_config.json")
    xdg = os.environ.get("XDG_CONFIG_HOME", os.path.join(home, ".config"))
    return os.path.join(xdg, "Claude", "claude_desktop_config.json")

def register_claude_desktop(server_script_path, config_path=None):
    cfg_path = claude_desktop_config_path(config_path)
    os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
    cfg = {}
    if os.path.isfile(cfg_path):
        with open(cfg_path) as f:
            try:
                cfg = json.load(f)
            except json.JSONDecodeError:
                warn(f"Could not parse existing config at {cfg_path}; it will be rewritten.")
    cfg.setdefault("mcpServers", {})
    cfg["mcpServers"]["robloxStudio"] = {
        "command": python_cmd(),
        "args": [server_script_path],
    }
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    ok(f"Claude Desktop config updated → {cfg_path}")
    info("Restart Claude Desktop to pick up the new server.")

# ── Claude Code ─────────────────────────────────────────────────────────────
def register_claude_code(server_script_path):
    if not shutil.which("claude"):
        warn("'claude' CLI not found. Printing the command to run manually:")
        info(f"  claude mcp add Roblox_Studio --scope user -- "
             f"{python_cmd()} {server_script_path}")
        return
    cmd = [
        "claude", "mcp", "add", "Roblox_Studio",
        "--scope", "user", "--",
        python_cmd(), server_script_path,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        ok("Registered with Claude Code (user scope).")
    else:
        warn("claude mcp add failed. Trying add-json fallback…")
        json_blob = json.dumps({
            "command": python_cmd(),
            "args": [server_script_path],
        })
        cmd2 = ["claude", "mcp", "add-json", "robloxStudio", json_blob]
        r2 = subprocess.run(cmd2, capture_output=True, text=True)
        if r2.returncode == 0:
            ok("Registered with Claude Code via add-json.")
        else:
            err("Registration failed. Run manually:")
            info(f"  claude mcp add Roblox_Studio --scope user -- "
                 f"{python_cmd()} {server_script_path}")

# ── OpenAI Codex ────────────────────────────────────────────────────────────
def codex_config_path():
    codex_home = os.environ.get("CODEX_HOME",
                                os.path.join(os.path.expanduser("~"), ".codex"))
    return os.path.join(codex_home, "config.toml")

def register_codex(server_script_path):
    if shutil.which("codex"):
        cmd = [
            "codex", "mcp", "add", "robloxStudio", "--",
            python_cmd(), server_script_path,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            ok("Registered with OpenAI Codex via CLI.")
            return
    cfg_path = codex_config_path()
    os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
    existing_text = ""
    if os.path.isfile(cfg_path):
        with open(cfg_path) as f:
            existing_text = f.read()
    if "Roblox_Studio" in existing_text:
        warn(f"'Roblox_Studio' already present in {cfg_path}. Skipping.")
        return
    entry = textwrap.dedent(f"""
        [mcp_servers.Roblox_Studio]
        command = [{python_cmd()!r}, {server_script_path!r}]
    """).lstrip()
    with open(cfg_path, "a") as f:
        if existing_text and not existing_text.endswith("\n"):
            f.write("\n")
        f.write(entry)
    ok(f"OpenAI Codex config updated → {cfg_path}")
    info("Restart Codex to pick up the new server.")

# ── OpenCode ─────────────────────────────────────────────────────────────────
def opencode_config_path():
    opencode_home = os.environ.get(
        "OPENCODE_HOME",
        os.path.join(os.path.expanduser("~"), ".config", "opencode"),
    )
    return os.path.join(opencode_home, "mcp.json")

def register_opencode(server_script_path):
    if shutil.which("opencode"):
        cmd = [
            "opencode", "mcp", "add", "roblox-studio-mcp", "--",
            python_cmd(), server_script_path,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            ok("Registered with OpenCode via CLI.")
            return
    cfg_path = opencode_config_path()
    os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
    cfg = {}
    if os.path.isfile(cfg_path):
        with open(cfg_path) as f:
            try:
                cfg = json.load(f)
            except json.JSONDecodeError:
                warn(f"Could not parse existing OpenCode config at {cfg_path}; it will be rewritten.")
    cfg.setdefault("mcpServers", {})
    cfg["mcpServers"]["roblox-studio-mcp"] = {
        "command": python_cmd(),
        "args": [server_script_path],
    }
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    ok(f"OpenCode config updated → {cfg_path}")
    info("Restart OpenCode to pick up the new server.")

# ── Generic JSON snippet ─────────────────────────────────────────────────────
def print_manual_json(server_script_path):
    snippet = {
        "mcpServers": {
            "Roblox_Studio": {
                "command": python_cmd(),
                "args": [server_script_path],
            }
        }
    }
    print()
    info("Add the following to your MCP client's config file:")
    print(json.dumps(snippet, indent=2))


# ---------------------------------------------------------------------------
# Main wizard
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Roblox Studio MCP Bridge installation wizard",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Examples:
              python install.py                              # fully interactive
              python install.py --non-interactive \\
                  --skill-dest ~/.codex/skills/ \\
                  --plugin-dir /path/to/Plugins \\
                  --server-path /opt/roblox-mcp/roblox_mcp_server.py \\
                  --agent claude-code
        """),
    )
    parser.add_argument("--non-interactive", action="store_true",
                        help="Skip all prompts; use defaults / flags only")
    parser.add_argument("--skill-dest",   default=None,
                        help="Where to copy the skill folder")
    parser.add_argument("--plugin-dir",   default=None,
                        help="Roblox Plugins folder (auto-detected if omitted)")
    parser.add_argument("--server-path",  default=None,
                        help=(
                            "Where to install / update the MCP server script. "
                            "Defaults to a platform-appropriate location if omitted."
                        ))
    # Keep old flag as a hidden alias for backwards compat
    parser.add_argument("--server-script", default=None,
                        help=argparse.SUPPRESS)
    parser.add_argument("--skip-skill",   action="store_true")
    parser.add_argument("--skip-plugin",  action="store_true")
    parser.add_argument("--skip-server",  action="store_true",
                        help="Skip installing / updating the MCP server script")
    parser.add_argument("--skip-mcp",     action="store_true",
                        help="Skip registering the server with any MCP client")
    parser.add_argument("--agent",        choices=["claude-desktop", "claude-code",
                                                    "codex", "opencode", "manual"],
                        default=None,
                        help="Which AI agent to register the MCP server with")
    parser.add_argument("--claude-desktop-config", default=None,
                        help="Optional path to Claude Desktop config JSON instead of OS default")
    args = parser.parse_args()

    # --server-script is an old alias for --server-path
    if args.server_script and not args.server_path:
        args.server_path = args.server_script

    interactive = not args.non_interactive

    print(c(BRIGHT, "\n  Roblox Studio MCP Bridge — Installation Wizard"))
    print(c(CYAN,   "  ------------------------------------------------"))
    info(f"Platform : {detect_platform()}" + (" (WSL)" if is_wsl() else ""))
    info(f"Installer root: {HERE}")
    if BUNDLE_ROOT != HERE:
        info(f"Bundled assets root: {BUNDLE_ROOT}")

    # ── Step 1: Skill ────────────────────────────────────────────────────────
    header("Step 1 / 4 — Install skill folder")
    if not args.skip_skill:
        if interactive:
            do_skill = ask_yn("Install the skill folder?", default=True)
        else:
            do_skill = bool(args.skill_dest)

        if do_skill:
            default_dest = os.path.join(
                os.path.expanduser("~"), ".codex", "skills", "Roblox_Studio"
            )
            if interactive:
                dest = ask("Destination", default_dest)
            else:
                dest = args.skill_dest or default_dest
            install_skill(os.path.expanduser(dest))
        else:
            warn("Skipped skill installation.")
    else:
        warn("Skipped (--skip-skill).")

    # ── Step 2: Plugin ───────────────────────────────────────────────────────
    header("Step 2 / 4 — Install Roblox Studio plugin")
    if not args.skip_plugin:
        if interactive:
            do_plugin = ask_yn("Install the Studio plugin?", default=True)
        else:
            do_plugin = True

        if do_plugin:
            auto_dirs = find_plugin_dirs(args.plugin_dir)
            if auto_dirs:
                info("Auto-detected plugin directories:")
                for i, d in enumerate(auto_dirs):
                    info(f"  [{i}] {d}")
                if interactive:
                    choice = ask("Enter index to use, or type a custom path", default="0")
                    try:
                        plugin_dir = auto_dirs[int(choice)]
                    except (ValueError, IndexError):
                        plugin_dir = os.path.expanduser(choice)
                else:
                    plugin_dir = args.plugin_dir or auto_dirs[0]
            else:
                warn("Could not auto-detect a Roblox Plugins folder.")
                if interactive:
                    plugin_dir = ask("Enter path to Roblox Plugins folder")
                    if not plugin_dir:
                        warn("No path given — skipping plugin install.")
                        do_plugin = False
                        plugin_dir = None
                else:
                    plugin_dir = args.plugin_dir
                    if not plugin_dir:
                        warn("No --plugin-dir given — skipping plugin install.")
                        do_plugin = False

            if do_plugin and plugin_dir:
                install_plugin(os.path.expanduser(plugin_dir))
        else:
            warn("Skipped plugin installation.")
    else:
        warn("Skipped (--skip-plugin).")

    # ── Step 3: Install / update MCP server script ───────────────────────────
    header("Step 3 / 4 — Install MCP server script")
    installed_server_path = None

    if not args.skip_server:
        default_path = args.server_path or default_server_install_path()

        if interactive:
            do_server = ask_yn("Install / update the MCP server script?", default=True)
        else:
            do_server = True

        if do_server:
            if interactive:
                chosen_path = ask(
                    "Where should roblox_mcp_server.py be installed?",
                    default_path,
                )
            else:
                chosen_path = default_path

            installed_server_path = install_server_script(
                chosen_path,
                force=args.non_interactive,
            )

            if installed_server_path:
                info(f"Server script is ready at: {installed_server_path}")
            else:
                warn("Server script could not be installed. MCP client registration will be skipped.")
        else:
            warn("Skipped server script installation.")
            # Still need a path for client registration — ask or fall back
            if interactive:
                existing = ask(
                    "Path to an existing roblox_mcp_server.py to use for client registration "
                    "(leave blank to skip registration too)",
                    "",
                )
                if existing.strip():
                    ep = os.path.abspath(os.path.expanduser(existing.strip()))
                    if os.path.isfile(ep):
                        installed_server_path = ep
                    else:
                        warn(f"File not found: {ep}")
            elif args.server_path and os.path.isfile(os.path.expanduser(args.server_path)):
                installed_server_path = os.path.abspath(os.path.expanduser(args.server_path))
    else:
        warn("Skipped (--skip-server).")
        # Honour --server-path if provided even when --skip-server is set
        if args.server_path:
            sp = os.path.abspath(os.path.expanduser(args.server_path))
            if os.path.isfile(sp):
                installed_server_path = sp
                info(f"Using server script at: {installed_server_path}")
            else:
                warn(f"--server-path '{sp}' does not exist; client registration will be skipped.")

    # ── Step 4: MCP client registration ──────────────────────────────────────
    header("Step 4 / 4 — Register with MCP client")

    if args.skip_mcp:
        warn("Skipped (--skip-mcp).")
    elif not installed_server_path:
        warn("No server script path available — skipping MCP client registration.")
        info("Re-run without --skip-server, or provide --server-path /path/to/roblox_mcp_server.py")
    else:
        server_script = installed_server_path
        if interactive:
            do_mcp = ask_yn("Register the MCP server with an AI client?", default=True)
        else:
            do_mcp = True

        if do_mcp:
            agents = {
                "1": ("claude-desktop", "Claude Desktop"),
                "2": ("claude-code",    "Claude Code (CLI)"),
                "3": ("codex",          "OpenAI Codex"),
                "4": ("opencode",       "OpenCode"),
                "5": ("manual",         "Show JSON snippet (manual setup)"),
                "0": (None,             "Skip"),
            }
            if interactive:
                print()
                for k, (_, label) in agents.items():
                    info(f"  [{k}] {label}")
                choice = ask("Which client?", default="2")
                agent_id = agents.get(choice, (None, None))[0]
            else:
                agent_id = args.agent

            if agent_id == "claude-desktop":
                custom_cfg_path = args.claude_desktop_config
                if interactive and not custom_cfg_path:
                    custom_cfg_path = ask(
                        "Optional Claude Desktop config path (blank for OS default)", ""
                    )
                    if not custom_cfg_path:
                        custom_cfg_path = None
                register_claude_desktop(server_script, custom_cfg_path)
            elif agent_id == "claude-code":
                register_claude_code(server_script)
            elif agent_id == "codex":
                register_codex(server_script)
            elif agent_id == "opencode":
                register_opencode(server_script)
            elif agent_id == "manual":
                print_manual_json(server_script)
            else:
                warn("Skipped MCP client registration.")
        else:
            warn("Skipped MCP client registration.")

    # ── Done ─────────────────────────────────────────────────────────────────
    header("Done!")
    print(c(GREEN, "  All selected steps completed."))
    print()
    info("Next steps:")
    info("  1. Open Roblox Studio")
    info("  2. Click 'Roblox MCP' in the Plugins toolbar")
    info("  3. Click 'Start Bridge Polling' in the widget")
    info("  4. In your AI agent, use: studio.get_connection_status")
    print()

if __name__ == "__main__":
    main()
