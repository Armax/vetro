#!/usr/bin/env python3
# vetro-hook-post-version: 2

import json
import os
import sys


HOST_CID = 2
HOST_PORT = 1025
TIMEOUT_SECONDS = 1
MAX_PAYLOAD = 4096
MARKER = "vetro-hook"
SCRIPT_DIR = "/usr/local/lib/vetro"
EVENTS = ("prompt-submit", "stop", "notification", "session-end")
SENTINEL_BEGIN = "# >>> vetro hooks >>>"
SENTINEL_END = "# <<< vetro hooks <<<"

CLAUDE_EVENTS = (
    ("UserPromptSubmit", "prompt-submit"),
    ("Stop", "stop"),
    ("Notification", "notification"),
)
CODEX_EVENTS = (
    ("UserPromptSubmit", "prompt-submit"),
    ("Stop", "stop"),
    ("SessionEnd", "session-end"),
)
GROK_EVENTS = (
    ("UserPromptSubmit", "prompt-submit"),
    ("Stop", "stop"),
    ("SessionEnd", "session-end"),
    ("Notification", "notification"),
)


def script_path():
    return os.path.realpath(__file__)


def wrapper_path(event):
    return os.path.join(SCRIPT_DIR, "vetro-hook-%s" % event)


def resolve_event():
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        return sys.argv[1]
    base = os.path.basename(sys.argv[0])
    prefix = "vetro-hook-"
    if base.startswith(prefix):
        name = base[len(prefix) :]
        if name.endswith(".py"):
            name = name[: -len(".py")]
        if name and name != "post":
            return name
    return None


def read_payload():
    if sys.stdin.isatty():
        return ""
    try:
        payload = sys.stdin.read(MAX_PAYLOAD)
    except OSError:
        return ""
    return payload.replace("\n", "").replace("\r", "").replace("\t", "")


def post(session_id, event, payload):
    import socket

    line = "%s\t%s\t%s\n" % (session_id, event, payload)
    connection = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        connection.settimeout(TIMEOUT_SECONDS)
        connection.connect((HOST_CID, HOST_PORT))
        connection.sendall(line.encode("utf-8"))
    finally:
        connection.close()


def emit_ok():
    try:
        sys.stdout.write("{}\n")
        sys.stdout.flush()
    except OSError:
        pass


def command_is_ours(command):
    return isinstance(command, str) and MARKER in command


def group(event, matcher):
    entry = {
        "hooks": [
            {
                "type": "command",
                "command": wrapper_path(event),
                "timeout": 5,
            }
        ]
    }
    if matcher:
        entry["matcher"] = ""
    return entry


def stripping_ours(groups):
    kept = []
    for raw in groups:
        if not isinstance(raw, dict):
            kept.append(raw)
            continue
        inner = list(raw.get("hooks") or [])
        had_ours = any(command_is_ours(item.get("command")) for item in inner if isinstance(item, dict))
        inner = [
            item
            for item in inner
            if not (isinstance(item, dict) and command_is_ours(item.get("command")))
        ]
        if not inner and had_ours:
            continue
        next_group = dict(raw)
        next_group["hooks"] = inner
        kept.append(next_group)
    return kept


def merge_events(root, event_map, matcher):
    hooks = root.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    for harness_event, arg in event_map:
        groups = hooks.get(harness_event)
        if not isinstance(groups, list):
            groups = []
        groups = stripping_ours(groups)
        groups.append(group(arg, matcher))
        hooks[harness_event] = groups
    root["hooks"] = hooks


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = handle.read()
    except FileNotFoundError:
        return {}
    except OSError:
        return None
    if not data.strip():
        return {}
    try:
        parsed = json.loads(data)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def write_json_if_changed(root, path):
    encoded = json.dumps(root, indent=2, sort_keys=True, separators=(",", ": "))
    encoded = encoded.replace("\\/", "/")
    if not encoded.endswith("\n"):
        encoded += "\n"
    try:
        with open(path, "r", encoding="utf-8") as handle:
            if handle.read() == encoded:
                return
    except OSError:
        pass
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(encoded)
    os.replace(tmp, path)


def home_dir():
    return os.environ.get("HOME") or os.path.expanduser("~")


def claude_settings_path():
    return os.path.join(home_dir(), ".claude", "settings.json")


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(home_dir(), ".codex")


def grok_hooks_path():
    root = os.environ.get("GROK_HOME")
    if root:
        return os.path.join(root, "hooks", "vetro-session.json")
    return os.path.join(home_dir(), ".grok", "hooks", "vetro-session.json")


def install_claude():
    path = claude_settings_path()
    root = read_json(path)
    if root is None:
        return
    merge_events(root, CLAUDE_EVENTS, True)
    write_json_if_changed(root, path)


def ensure_codex_sentinel():
    # codex >= 0.147 types `hooks` as a table; the old `hooks = true` boolean
    # makes every invocation fail config parsing, so migrate managed blocks
    # to an empty `[hooks]` table (0.147 reads hooks.json without any flag).
    path = os.path.join(codex_home(), "config.toml")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        text = ""
    except OSError:
        return
    managed = SENTINEL_BEGIN in text and SENTINEL_END in text
    outside = text
    if managed:
        start = text.index(SENTINEL_BEGIN)
        end = text.index(SENTINEL_END) + len(SENTINEL_END)
        outside = text[:start] + text[end:]
    has_table = any(
        line.strip().startswith("[hooks]") for line in outside.splitlines()
    )
    body = "" if has_table else "[hooks]\n"
    block = "%s\n%s%s" % (SENTINEL_BEGIN, body, SENTINEL_END)
    if managed:
        updated = text[:start] + block + text[end:]
        if updated != text:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(updated)
        return
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("hooks") and "=" in stripped:
            return
    if has_table:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n" + block + "\n")


def install_codex():
    path = os.path.join(codex_home(), "hooks.json")
    root = read_json(path)
    if root is None:
        return
    merge_events(root, CODEX_EVENTS, False)
    write_json_if_changed(root, path)
    ensure_codex_sentinel()


def install_grok():
    root = {}
    merge_events(root, GROK_EVENTS, False)
    write_json_if_changed(root, grok_hooks_path())


def ensure_wrappers():
    src = script_path()
    for event in EVENTS:
        dest = wrapper_path(event)
        try:
            if os.path.islink(dest) or os.path.exists(dest):
                try:
                    if os.path.samefile(dest, src):
                        continue
                except OSError:
                    pass
                os.remove(dest)
            os.symlink(os.path.basename(src), dest)
        except OSError:
            pass


def install_hooks():
    ensure_wrappers()
    install_claude()
    install_codex()
    install_grok()


def post_event():
    if os.environ.get("VETRO_HOOKS_DISABLED") == "1":
        return
    session_id = os.environ.get("VETRO_SESSION_ID", "").strip()
    event = resolve_event()
    if not event:
        return
    post(session_id, event, read_payload())


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--install":
        install_hooks()
        return
    try:
        post_event()
    except Exception:
        pass
    emit_ok()


if __name__ == "__main__":
    main()
