#!/bin/bash

set -euo pipefail
set -E

readonly LOG_FILE="/var/log/vetro-provision.log"
readonly STATUS_DIRECTORY="/var/lib/vetro"
readonly STATUS_FILE="${STATUS_DIRECTORY}/provision-status"
readonly AGENTS_CONF="/etc/vetro/agents.conf"
readonly DESKTOP_CONF="/etc/vetro/desktop.conf"
# xorg is explicit: with --no-install-recommends, lightdm/xfce4 pull no X server.
readonly DESKTOP_PACKAGES="xorg xfce4 lightdm lightdm-gtk-greeter dbus-x11 spice-vdagent"
readonly CUSTOM_SCRIPT="/usr/local/lib/vetro/custom-setup.sh"
readonly CUSTOM_SCRIPT_LOG="${STATUS_DIRECTORY}/custom-script.log"
readonly GROK_PATH_LINE='export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"'
readonly -a DEFAULT_AGENTS=(claude codex grok)
readonly -a BASE_PACKAGES=(
    git
    curl
    ripgrep
    build-essential
    python3
    rsync
    nftables
    openssh-client
    ca-certificates
    gnupg
)
readonly -a PROVISION_PHASES=(
    apt-base
    node
    claude
    codex
    grok
    workdir
    desktop
    prune
)
readonly -a PRUNED_TIMERS=(
    apt-daily.timer
    apt-daily-upgrade.timer
    man-db.timer
    e2scrub_all.timer
)

umask 022
exec >>"${LOG_FILE}" 2>&1

# Single-instance guard: the host re-kicks provisioning whenever it is
# incomplete (e.g. after an interrupted boot), and a concurrent run would
# fight over the apt/dpkg locks. Losing the flock is a clean no-op exit.
exec 200>/var/lock/vetro-provision.lock
if ! flock -n 200; then
    echo "provision already running; exiting"
    exit 0
fi
install -d -m 0755 "${STATUS_DIRECTORY}"
touch "${STATUS_FILE}"
chmod 0644 "${STATUS_FILE}"

# Agent credentials must never reach package managers, installers, or diagnostic output.
unset ANTHROPIC_API_KEY OPENAI_API_KEY XAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN || true

mode="${1:-provision}"
current_phase="all"
case "${mode}" in
    update-agents|update-agent)
        current_phase="update"
        ;;
    desktop)
        current_phase="desktop"
        ;;
esac

append_marker() {
    local marker="$1"
    printf '%s\n' "${marker}" >>"${STATUS_FILE}"
    printf '%s\n' "${marker}"
}

on_error() {
    local rc=$?
    trap - ERR
    set +e
    append_marker "PHASE:${current_phase}:FAIL rc=${rc}"
    exit "${rc}"
}
trap on_error ERR

if (( EUID != 0 )); then
    echo "provision.sh must run as root"
    false
fi

if [[ "${mode}" == "update-agent" ]]; then
    if (( $# != 2 )); then
        echo "usage: provision.sh update-agent {claude|codex|grok}"
        false
    fi
elif (( $# > 1 )) \
    || [[ "${mode}" != "provision" && "${mode}" != "update-agents" && "${mode}" != "desktop" ]]; then
    echo "usage: provision.sh [update-agents|update-agent <name>|desktop]"
    false
fi

phase_is_done() {
    grep -Fqx "PHASE:$1:DONE" "${STATUS_FILE}" 2>/dev/null
}

phase_is_skipped() {
    grep -Fqx "PHASE:$1:SKIP" "${STATUS_FILE}" 2>/dev/null
}

phase_is_failed() {
    grep -q "^PHASE:$1:FAIL" "${STATUS_FILE}" 2>/dev/null
}

phase_is_terminal() {
    phase_is_done "$1" || phase_is_skipped "$1"
}

phase_is_marked() {
    phase_is_terminal "$1" || phase_is_failed "$1"
}

load_selected_agents() {
    SELECTED_AGENTS=()
    if [[ -r "${AGENTS_CONF}" ]]; then
        read -r -a SELECTED_AGENTS < "${AGENTS_CONF}" || true
    else
        SELECTED_AGENTS=("${DEFAULT_AGENTS[@]}")
    fi
}

agent_is_selected() {
    local agent="$1"
    local selected
    for selected in "${SELECTED_AGENTS[@]+"${SELECTED_AGENTS[@]}"}"; do
        if [[ "${selected}" == "${agent}" ]]; then
            return 0
        fi
    done
    return 1
}

is_known_agent() {
    case "$1" in
        claude|codex|grok) return 0 ;;
        *) return 1 ;;
    esac
}

skip_phase() {
    local phase="$1"
    if phase_is_marked "${phase}"; then
        return
    fi
    append_marker "PHASE:${phase}:SKIP"
}

run_selected_agent_phase() {
    local agent="$1"
    local installer="$2"
    if agent_is_selected "${agent}"; then
        run_phase "${agent}" "${installer}"
    else
        skip_phase "${agent}"
    fi
}

run_selected_update_phase() {
    local agent="$1"
    local updater="$2"
    if agent_is_selected "${agent}"; then
        run_update_phase "update-${agent}" "${updater}"
    else
        skip_phase "update-${agent}"
    fi
}

provisioning_is_complete() {
    local phase
    for phase in "${PROVISION_PHASES[@]}"; do
        phase_is_terminal "${phase}" || return 1
    done
    if [[ -f "${CUSTOM_SCRIPT}" ]]; then
        phase_is_done custom || phase_is_failed custom || phase_is_skipped custom || return 1
    fi
}

run_phase() {
    local phase="$1"
    shift
    if phase_is_done "${phase}"; then
        return
    fi

    current_phase="${phase}"
    append_marker "PHASE:${phase}:START"
    "$@"
    append_marker "PHASE:${phase}:DONE"
    current_phase="all"
}

run_update_phase() {
    local phase="$1"
    shift
    current_phase="${phase}"
    append_marker "PHASE:${phase}:START"
    "$@"
    append_marker "PHASE:${phase}:DONE"
    current_phase="update"
}

package_is_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

ensure_vsock_ssh_bridge() {
    local bridge_script
    local bridge_unit
    local bridge_changed=false

    install -d -m 0755 /usr/local/lib/vetro

    bridge_script="$(mktemp)"
    cat >"${bridge_script}" <<'PYTHON'
#!/usr/bin/env python3

import socket
import sys
import threading


VSOCK_PORT = 1026
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
BUFFER_SIZE = 64 * 1024


def close_on_error(source, destination):
    """Interrupt both pump directions after an unrecoverable socket error."""
    for connection in (source, destination):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def pump(source, destination):
    """Copy one half of a full-duplex stream and preserve a clean half-close."""
    try:
        while True:
            data = source.recv(BUFFER_SIZE)
            if not data:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            destination.sendall(data)
    except OSError:
        close_on_error(source, destination)


def bridge_connection(vsock_connection):
    """Connect one host vsock stream to the guest's loopback SSH server."""
    ssh_connection = None
    try:
        ssh_connection = socket.create_connection((SSH_HOST, SSH_PORT), timeout=5)
        ssh_connection.settimeout(None)

        host_to_ssh = threading.Thread(
            target=pump,
            args=(vsock_connection, ssh_connection),
            daemon=True,
        )
        ssh_to_host = threading.Thread(
            target=pump,
            args=(ssh_connection, vsock_connection),
            daemon=True,
        )
        host_to_ssh.start()
        ssh_to_host.start()
        host_to_ssh.join()
        ssh_to_host.join()
    except OSError as error:
        print(f"could not connect to {SSH_HOST}:{SSH_PORT}: {error}", file=sys.stderr)
    finally:
        vsock_connection.close()
        if ssh_connection is not None:
            ssh_connection.close()


def main():
    """Accept host connections forever, with one independent bridge per client."""
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    listener.listen()

    while True:
        try:
            connection, _ = listener.accept()
        except InterruptedError:
            continue
        threading.Thread(
            target=bridge_connection,
            args=(connection,),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
PYTHON
    if [[ ! -f /usr/local/lib/vetro/vsock-ssh-bridge.py ]] \
        || ! cmp -s "${bridge_script}" /usr/local/lib/vetro/vsock-ssh-bridge.py; then
        install -o root -g root -m 0755 \
            "${bridge_script}" /usr/local/lib/vetro/vsock-ssh-bridge.py
        bridge_changed=true
    fi
    rm -f "${bridge_script}"
    chown root:root /usr/local/lib/vetro/vsock-ssh-bridge.py
    chmod 0755 /usr/local/lib/vetro/vsock-ssh-bridge.py

    bridge_unit="$(mktemp)"
    cat >"${bridge_unit}" <<'UNIT'
[Unit]
Description=Vetro vsock SSH bridge
After=network.target ssh.service sshd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-ssh-bridge.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    if [[ ! -f /etc/systemd/system/vetro-vsock-ssh.service ]] \
        || ! cmp -s "${bridge_unit}" /etc/systemd/system/vetro-vsock-ssh.service; then
        install -o root -g root -m 0644 \
            "${bridge_unit}" /etc/systemd/system/vetro-vsock-ssh.service
        bridge_changed=true
    fi
    rm -f "${bridge_unit}"
    chown root:root /etc/systemd/system/vetro-vsock-ssh.service
    chmod 0644 /etc/systemd/system/vetro-vsock-ssh.service

    systemctl daemon-reload
    systemctl enable --now vetro-vsock-ssh.service
    if [[ "${bridge_changed}" == true ]]; then
        systemctl restart vetro-vsock-ssh.service
    fi
}

ensure_vsock_port_bridge() {
    local bridge_script
    local bridge_unit
    local bridge_changed=false

    install -d -m 0755 /usr/local/lib/vetro

    bridge_script="$(mktemp)"
    cat >"${bridge_script}" <<'PYTHON'
#!/usr/bin/env python3
# vetro-vsock-port-bridge-version: 1

import socket
import sys
import threading


VSOCK_PORT = 1027
TARGET_HOST = "127.0.0.1"
BUFFER_SIZE = 64 * 1024
CONNECT_TIMEOUT = 5
REQUEST_LIMIT = 64


def close_on_error(source, destination):
    """Interrupt both pump directions after an unrecoverable socket error."""
    for connection in (source, destination):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def pump(source, destination):
    """Copy one half of a full-duplex stream and preserve a clean half-close."""
    try:
        while True:
            data = source.recv(BUFFER_SIZE)
            if not data:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            destination.sendall(data)
    except OSError:
        close_on_error(source, destination)


def read_request_line(connection):
    buf = bytearray()
    while b"\n" not in buf:
        chunk = connection.recv(1)
        if not chunk:
            return None
        buf.extend(chunk)
        if len(buf) > REQUEST_LIMIT:
            return None
    return bytes(buf).decode("ascii", errors="replace").strip()


def parse_connect_port(line):
    if not line.startswith("CONNECT "):
        return None
    token = line[8:].strip()
    if not token.isdigit():
        return None
    port = int(token)
    if port < 1 or port > 65535:
        return None
    return port


def send_line(connection, text):
    connection.sendall((text + "\n").encode("ascii", errors="replace"))


def bridge_connection(vsock_connection):
    """Connect one host vsock stream to a guest loopback TCP port."""
    target_connection = None
    try:
        vsock_connection.settimeout(CONNECT_TIMEOUT)
        line = read_request_line(vsock_connection)
        if line is None:
            send_line(vsock_connection, "ERR invalid request")
            return
        port = parse_connect_port(line)
        if port is None:
            send_line(vsock_connection, "ERR invalid port")
            return
        try:
            target_connection = socket.create_connection(
                (TARGET_HOST, port),
                timeout=CONNECT_TIMEOUT,
            )
        except OSError as error:
            send_line(vsock_connection, f"ERR {error}")
            return

        target_connection.settimeout(None)
        vsock_connection.settimeout(None)
        send_line(vsock_connection, "OK")

        host_to_target = threading.Thread(
            target=pump,
            args=(vsock_connection, target_connection),
            daemon=True,
        )
        target_to_host = threading.Thread(
            target=pump,
            args=(target_connection, vsock_connection),
            daemon=True,
        )
        host_to_target.start()
        target_to_host.start()
        host_to_target.join()
        target_to_host.join()
    except OSError as error:
        try:
            send_line(vsock_connection, f"ERR {error}")
        except OSError:
            pass
        print(f"could not bridge vsock port: {error}", file=sys.stderr)
    finally:
        vsock_connection.close()
        if target_connection is not None:
            target_connection.close()


def main():
    """Accept host connections forever, with one independent bridge per client."""
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    listener.listen()

    while True:
        try:
            connection, _ = listener.accept()
        except InterruptedError:
            continue
        threading.Thread(
            target=bridge_connection,
            args=(connection,),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
PYTHON
    if [[ ! -f /usr/local/lib/vetro/vsock-port-bridge.py ]] \
        || ! cmp -s "${bridge_script}" /usr/local/lib/vetro/vsock-port-bridge.py; then
        install -o root -g root -m 0755 \
            "${bridge_script}" /usr/local/lib/vetro/vsock-port-bridge.py
        bridge_changed=true
    fi
    rm -f "${bridge_script}"
    chown root:root /usr/local/lib/vetro/vsock-port-bridge.py
    chmod 0755 /usr/local/lib/vetro/vsock-port-bridge.py

    bridge_unit="$(mktemp)"
    cat >"${bridge_unit}" <<'UNIT'
[Unit]
Description=Vetro vsock port bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-port-bridge.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    if [[ ! -f /etc/systemd/system/vetro-vsock-port.service ]] \
        || ! cmp -s "${bridge_unit}" /etc/systemd/system/vetro-vsock-port.service; then
        install -o root -g root -m 0644 \
            "${bridge_unit}" /etc/systemd/system/vetro-vsock-port.service
        bridge_changed=true
    fi
    rm -f "${bridge_unit}"
    chown root:root /etc/systemd/system/vetro-vsock-port.service
    chmod 0644 /etc/systemd/system/vetro-vsock-port.service

    systemctl daemon-reload
    systemctl enable --now vetro-vsock-port.service
    if [[ "${bridge_changed}" == true ]]; then
        systemctl restart vetro-vsock-port.service
    fi
}

ensure_guest_hooks() {
    local hook_script
    local event

    install -d -m 0755 /usr/local/lib/vetro

    hook_script="$(mktemp)"
    cat >"${hook_script}" <<'HOOKPYTHON'
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
HOOKPYTHON
    if [[ ! -f /usr/local/lib/vetro/vetro-hook-post.py ]] \
        || ! cmp -s "${hook_script}" /usr/local/lib/vetro/vetro-hook-post.py; then
        install -o root -g root -m 0755 \
            "${hook_script}" /usr/local/lib/vetro/vetro-hook-post.py
    fi
    rm -f "${hook_script}"
    chown root:root /usr/local/lib/vetro/vetro-hook-post.py
    chmod 0755 /usr/local/lib/vetro/vetro-hook-post.py

    for event in prompt-submit stop notification session-end; do
        ln -sfn vetro-hook-post.py "/usr/local/lib/vetro/vetro-hook-${event}"
    done

    sudo -H -u vetro /usr/bin/python3 /usr/local/lib/vetro/vetro-hook-post.py --install
}

ensure_portwatch() {
    local watch_script
    local watch_unit
    local watch_changed=false

    install -d -m 0755 /usr/local/lib/vetro

    watch_script="$(mktemp)"
    cat >"${watch_script}" <<'PYTHON'
#!/usr/bin/env python3
# vetro-portwatch-version: 2

import errno
import json
import socket
import subprocess
import threading
import time


HOST_CID = 2
HOST_PORT = 1029
INTERVAL_SECONDS = 2
CONNECT_TIMEOUT = 1
EXCLUDED_PORTS = set([22, 53, 5353, 5355]) | set(range(1024, 1030))
REFUSED_COOLDOWN_SECONDS = 10

listen_ports = set()
refused_queue = []
refused_seen = {}
state_lock = threading.Lock()


def parse_proc_net(path):
    ports = set()
    try:
        with open(path, "r", encoding="ascii", errors="replace") as handle:
            next(handle, None)
            for line in handle:
                parts = line.split()
                if len(parts) < 4 or parts[3] != "0A":
                    continue
                local = parts[1]
                separator = local.rfind(":")
                if separator < 0:
                    continue
                try:
                    port = int(local[separator + 1 :], 16)
                except ValueError:
                    continue
                if 1 <= port <= 65535:
                    ports.add(port)
    except OSError:
        pass
    return ports


def all_listen_ports():
    ports = parse_proc_net("/proc/net/tcp")
    ports.update(parse_proc_net("/proc/net/tcp6"))
    return ports


def host_mirror_ports():
    # Ports the host-bridge binds on our loopback are the Mac's services, not
    # guest listeners; reporting them would loop them back as phantom mirrors.
    ports = set()
    try:
        with open("/etc/vetro/host-mirror.ports") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#"):
                    ports.add(int(line))
    except Exception:
        pass
    return ports


def current_ports():
    hidden = EXCLUDED_PORTS | host_mirror_ports()
    return set(port for port in all_listen_ports() if port not in hidden)


def send_json(connection, payload):
    connection.sendall((json.dumps(payload) + "\n").encode("utf-8"))


def close_quietly(connection):
    if connection is None:
        return
    try:
        connection.close()
    except OSError:
        pass


def connect_host():
    connection = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        connection.settimeout(CONNECT_TIMEOUT)
        connection.connect((HOST_CID, HOST_PORT))
        connection.settimeout(None)
        return connection
    except OSError:
        close_quietly(connection)
        return None


def install_refused_log_rule():
    """Returns True once the loopback-RST log rule is confirmed present.

    nftables is installed by provisioning after this daemon first starts, so
    the caller retries until this succeeds.
    """
    try:
        listed = subprocess.run(
            ["nft", "list", "table", "inet", "vetro"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if listed.returncode == 0 and b"vetro-refused" in listed.stdout:
            return True
        if listed.returncode == 0:
            subprocess.run(
                ["nft", "delete", "table", "inet", "vetro"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        ruleset = (
            "table inet vetro {\n"
            "  chain output {\n"
            "    type filter hook output priority 0; policy accept;\n"
            '    oifname "lo" ip daddr 127.0.0.0/8 '
            "tcp flags & (rst|ack) == rst|ack "
            'log prefix "vetro-refused "\n'
            "  }\n"
            "}\n"
        )
        loaded = subprocess.run(
            ["nft", "-f", "-"],
            input=ruleset.encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return loaded.returncode == 0
    except Exception:
        return False


def field_value(line, key):
    index = line.find(key)
    if index < 0:
        return None
    start = index + len(key)
    end = start
    while end < len(line) and not line[end].isspace():
        end += 1
    if end == start:
        return None
    return line[start:end]


def parse_refused_kmsg(line):
    if "vetro-refused " not in line:
        return None
    src = field_value(line, "SRC=")
    if src is None or not src.startswith("127."):
        return None
    spt = field_value(line, "SPT=")
    if spt is None:
        return None
    try:
        port = int(spt)
    except ValueError:
        return None
    if 1 <= port <= 65535:
        return port
    return None


def ephemeral_range_start():
    try:
        with open("/proc/sys/net/ipv4/ip_local_port_range") as handle:
            return int(handle.read().split()[0])
    except Exception:
        return 32768


EPHEMERAL_START = ephemeral_range_start()


def enqueue_refused(port):
    # Teardown RSTs from ephemeral client ports are not service refusals.
    if port >= EPHEMERAL_START:
        return
    now = time.monotonic()
    with state_lock:
        if port in EXCLUDED_PORTS or port in listen_ports:
            return
        last = refused_seen.get(port)
        if last is not None and now - last < REFUSED_COOLDOWN_SECONDS:
            return
        refused_seen[port] = now
        refused_queue.append(port)


def take_refused(listening):
    with state_lock:
        pending = list(refused_queue)
        refused_queue[:] = []
    ready = []
    seen = set()
    for port in pending:
        if port in EXCLUDED_PORTS or port in listening or port in seen:
            continue
        seen.add(port)
        ready.append(port)
    return ready


def read_kmsg():
    try:
        handle = open("/dev/kmsg", "r", errors="replace")
    except OSError:
        return
    try:
        while True:
            try:
                line = handle.readline()
            except OSError as error:
                if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    time.sleep(0.05)
                    continue
                time.sleep(0.2)
                continue
            if not line:
                time.sleep(0.05)
                continue
            port = parse_refused_kmsg(line)
            if port is not None:
                enqueue_refused(port)
    finally:
        try:
            handle.close()
        except OSError:
            pass


def start_kmsg_thread():
    thread = threading.Thread(target=read_kmsg, name="vetro-portwatch-kmsg")
    thread.daemon = True
    thread.start()


def main():
    refused_rule_ready = install_refused_log_rule()
    start_kmsg_thread()
    previous = None
    connection = None

    while True:
        try:
            if not refused_rule_ready:
                refused_rule_ready = install_refused_log_rule()
            listening = all_listen_ports()
            ports = set(port for port in listening if port not in EXCLUDED_PORTS)
            with state_lock:
                listen_ports.clear()
                listen_ports.update(listening)
            if connection is None:
                connection = connect_host()
                if connection is None:
                    time.sleep(INTERVAL_SECONDS)
                    continue
                try:
                    send_json(connection, {"snapshot": sorted(ports)})
                    previous = ports
                except OSError:
                    close_quietly(connection)
                    connection = None
                    time.sleep(INTERVAL_SECONDS)
                    continue
            elif previous is None or ports != previous:
                added = sorted(ports - previous)
                removed = sorted(previous - ports)
                try:
                    send_json(connection, {"added": added, "removed": removed})
                    previous = ports
                except OSError:
                    close_quietly(connection)
                    connection = None
                    time.sleep(INTERVAL_SECONDS)
                    continue
            refused = take_refused(listening)
            if refused:
                try:
                    send_json(connection, {"refused": refused})
                except OSError:
                    close_quietly(connection)
                    connection = None
        except Exception:
            close_quietly(connection)
            connection = None
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
PYTHON
    if [[ ! -f /usr/local/lib/vetro/vetro-portwatch.py ]] \
        || ! cmp -s "${watch_script}" /usr/local/lib/vetro/vetro-portwatch.py; then
        install -o root -g root -m 0755 \
            "${watch_script}" /usr/local/lib/vetro/vetro-portwatch.py
        watch_changed=true
    fi
    rm -f "${watch_script}"
    chown root:root /usr/local/lib/vetro/vetro-portwatch.py
    chmod 0755 /usr/local/lib/vetro/vetro-portwatch.py

    watch_unit="$(mktemp)"
    cat >"${watch_unit}" <<'UNIT'
[Unit]
Description=Vetro port watcher
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vetro-portwatch.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    if [[ ! -f /etc/systemd/system/vetro-portwatch.service ]] \
        || ! cmp -s "${watch_unit}" /etc/systemd/system/vetro-portwatch.service; then
        install -o root -g root -m 0644 \
            "${watch_unit}" /etc/systemd/system/vetro-portwatch.service
        watch_changed=true
    fi
    rm -f "${watch_unit}"
    chown root:root /etc/systemd/system/vetro-portwatch.service
    chmod 0644 /etc/systemd/system/vetro-portwatch.service

    systemctl daemon-reload
    systemctl enable --now vetro-portwatch.service
    if [[ "${watch_changed}" == true ]]; then
        systemctl restart vetro-portwatch.service
    fi
}

ensure_vsock_host_bridge() {
    local bridge_script
    local bridge_unit
    local bridge_changed=false

    install -d -m 0755 /usr/local/lib/vetro
    install -d -m 0755 /etc/vetro
    if [[ ! -f /etc/vetro/host-mirror.ports ]]; then
        install -o root -g root -m 0644 /dev/null /etc/vetro/host-mirror.ports
    fi

    bridge_script="$(mktemp)"
    cat >"${bridge_script}" <<'PYTHON'
#!/usr/bin/env python3
# vetro-vsock-host-bridge-version: 1

import socket
import sys
import threading
import time


HOST_CID = 2
HOST_PORT = 1028
PORTS_FILE = "/etc/vetro/host-mirror.ports"
BUFFER_SIZE = 64 * 1024
CONNECT_TIMEOUT = 5
REQUEST_LIMIT = 64


def close_on_error(source, destination):
    """Interrupt both pump directions after an unrecoverable socket error."""
    for connection in (source, destination):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def pump(source, destination):
    """Copy one half of a full-duplex stream and preserve a clean half-close."""
    try:
        while True:
            data = source.recv(BUFFER_SIZE)
            if not data:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            destination.sendall(data)
    except OSError:
        close_on_error(source, destination)


def read_reply_line(connection):
    buf = bytearray()
    while b"\n" not in buf:
        chunk = connection.recv(1)
        if not chunk:
            return None
        buf.extend(chunk)
        if len(buf) > REQUEST_LIMIT:
            return None
    return bytes(buf).decode("ascii", errors="replace").strip()


def read_ports():
    ports = []
    seen = set()
    try:
        with open(PORTS_FILE, "r", encoding="ascii", errors="replace") as handle:
            for raw in handle:
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if not stripped.isdigit():
                    continue
                port = int(stripped)
                if port < 1 or port > 65535 or port in seen:
                    continue
                seen.add(port)
                ports.append(port)
    except FileNotFoundError:
        return []
    except OSError:
        return []
    return ports


def bridge_client(client_connection, port):
    """Connect one guest loopback client to the host reverse vsock bridge."""
    vsock_connection = None
    try:
        vsock_connection = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        vsock_connection.settimeout(CONNECT_TIMEOUT)
        vsock_connection.connect((HOST_CID, HOST_PORT))
        vsock_connection.sendall(("CONNECT %s\n" % port).encode("ascii"))
        reply = read_reply_line(vsock_connection)
        if reply != "OK":
            return

        vsock_connection.settimeout(None)
        client_connection.settimeout(None)

        client_to_host = threading.Thread(
            target=pump,
            args=(client_connection, vsock_connection),
            daemon=True,
        )
        host_to_client = threading.Thread(
            target=pump,
            args=(vsock_connection, client_connection),
            daemon=True,
        )
        client_to_host.start()
        host_to_client.start()
        client_to_host.join()
        host_to_client.join()
    except OSError as error:
        print("could not bridge host port %s: %s" % (port, error), file=sys.stderr)
    finally:
        client_connection.close()
        if vsock_connection is not None:
            vsock_connection.close()


def listen_port(port):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen()
    except OSError as error:
        print("could not bind 127.0.0.1:%s: %s" % (port, error), file=sys.stderr)
        listener.close()
        return

    while True:
        try:
            connection, _ = listener.accept()
        except InterruptedError:
            continue
        threading.Thread(
            target=bridge_client,
            args=(connection, port),
            daemon=True,
        ).start()


def main():
    for port in read_ports():
        threading.Thread(target=listen_port, args=(port,), daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
PYTHON
    if [[ ! -f /usr/local/lib/vetro/vsock-host-bridge.py ]] \
        || ! cmp -s "${bridge_script}" /usr/local/lib/vetro/vsock-host-bridge.py; then
        install -o root -g root -m 0755 \
            "${bridge_script}" /usr/local/lib/vetro/vsock-host-bridge.py
        bridge_changed=true
    fi
    rm -f "${bridge_script}"
    chown root:root /usr/local/lib/vetro/vsock-host-bridge.py
    chmod 0755 /usr/local/lib/vetro/vsock-host-bridge.py

    bridge_unit="$(mktemp)"
    cat >"${bridge_unit}" <<'UNIT'
[Unit]
Description=Vetro vsock host bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/vetro/vsock-host-bridge.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    if [[ ! -f /etc/systemd/system/vetro-vsock-host.service ]] \
        || ! cmp -s "${bridge_unit}" /etc/systemd/system/vetro-vsock-host.service; then
        install -o root -g root -m 0644 \
            "${bridge_unit}" /etc/systemd/system/vetro-vsock-host.service
        bridge_changed=true
    fi
    rm -f "${bridge_unit}"
    chown root:root /etc/systemd/system/vetro-vsock-host.service
    chmod 0644 /etc/systemd/system/vetro-vsock-host.service

    systemctl daemon-reload
    systemctl enable --now vetro-vsock-host.service
    if [[ "${bridge_changed}" == true ]]; then
        systemctl restart vetro-vsock-host.service
    fi
}

install_apt_base() {
    local package
    local all_installed=true
    for package in "${BASE_PACKAGES[@]}"; do
        if ! package_is_installed "${package}"; then
            all_installed=false
            break
        fi
    done
    if [[ "${all_installed}" == true ]]; then
        echo "apt-base already installed"
        return
    fi

    # Recover from a previous run interrupted mid-unpack (e.g. VM stopped).
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${BASE_PACKAGES[@]}"
}

node_is_compatible() {
    local version
    local major
    command -v node >/dev/null 2>&1 || return 1
    version="$(node --version 2>/dev/null)" || return 1
    [[ "${version}" =~ ^v([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    (( major >= 22 ))
}

install_node() {
    if node_is_compatible; then
        echo "node $(node --version) already satisfies v22+"
        return
    fi

    # NodeSource is system-wide: root provisioning needs no per-shell nvm setup,
    # and Node is immediately available to systemd units and every guest user.
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    node_is_compatible
}

claude_is_installed() {
    command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1
}

install_claude() {
    local repo_line
    repo_line='deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/latest latest main'
    if claude_is_installed; then
        echo "claude already installed"
        return
    fi

    if [[ ! -d /etc/apt/keyrings ]] \
        || [[ "$(stat -c '%a' /etc/apt/keyrings)" != "755" ]]; then
        install -d -m 0755 /etc/apt/keyrings
    fi
    if [[ ! -s /etc/apt/keyrings/claude-code.asc ]]; then
        curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
            -o /etc/apt/keyrings/claude-code.asc
    fi
    if [[ ! -f /etc/apt/sources.list.d/claude-code.list ]] \
        || ! grep -Fqx "${repo_line}" /etc/apt/sources.list.d/claude-code.list; then
        printf '%s\n' "${repo_line}" >/etc/apt/sources.list.d/claude-code.list
    fi

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code
    claude_is_installed
}

codex_is_installed() {
    command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1
}

install_codex() {
    if codex_is_installed; then
        echo "codex already installed"
        return
    fi
    npm install -g @openai/codex
    codex_is_installed
}

vetro_home_directory() {
    getent passwd vetro | cut -d: -f6
}

grok_is_installed() {
    sudo -u vetro bash -lc 'grok --version' >/dev/null 2>&1
}

ensure_grok_path_file() {
    local path="$1"
    local prepend="$2"
    local temporary_file

    if [[ ! -e "${path}" ]]; then
        install -o vetro -g vetro -m 0644 /dev/null "${path}"
    fi
    if grep -Fqx "${GROK_PATH_LINE}" "${path}" 2>/dev/null; then
        return
    fi

    if [[ "${prepend}" == true ]]; then
        temporary_file="$(mktemp)"
        printf '%s\n' "${GROK_PATH_LINE}" >"${temporary_file}"
        cat "${path}" >>"${temporary_file}"
        install -o vetro -g vetro -m 0644 "${temporary_file}" "${path}"
        rm -f "${temporary_file}"
    else
        printf '%s\n' "${GROK_PATH_LINE}" >>"${path}"
        chown vetro:vetro "${path}"
        chmod 0644 "${path}"
    fi
}

ensure_grok_paths() {
    local home_directory
    home_directory="$(vetro_home_directory)"
    [[ -n "${home_directory}" ]]
    ensure_grok_path_file "${home_directory}/.profile" false
    # Prepend so Debian's non-interactive .bashrc early-return cannot hide the path.
    ensure_grok_path_file "${home_directory}/.bashrc" true
}

install_grok() {
    if ! grok_is_installed; then
        sudo -u vetro bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash'
    else
        echo "grok already installed"
    fi
    ensure_grok_paths
    grok_is_installed
}

create_work_directory() {
    local golden_exclude
    golden_exclude="$(mktemp)"
    cat >"${golden_exclude}" <<'EXCLUDE'
.codex
.grok/auth.json
.grok/auth.json.lock
.grok/agent_id
.grok/logs
.grok/projects
.grok/active_sessions.json
.grok/memtrace
.config/vetro/env
.config/vetro/credentials-version
.config/vetro/agent-auth-version
.git-credentials
.claude.json
.claude/.credentials.json
EXCLUDE
    install -o root -g root -m 0644 \
        "${golden_exclude}" /var/lib/vetro/golden-exclude
    rm -f "${golden_exclude}"

    if [[ -d /workspace ]] && [[ "$(stat -c '%U:%G' /workspace)" == "vetro:vetro" ]]; then
        echo "/workspace already exists with vetro ownership"
        return
    fi
    install -d -o vetro -g vetro /workspace
}

desktop_is_enabled() {
    [[ -r "${DESKTOP_CONF}" ]] && grep -Fqx "DESKTOP=1" "${DESKTOP_CONF}"
}

install_desktop() {
    local package
    local all_installed=true
    for package in ${DESKTOP_PACKAGES}; do
        if ! package_is_installed "${package}"; then
            all_installed=false
            break
        fi
    done
    if [[ "${all_installed}" != true ]]; then
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${DESKTOP_PACKAGES}
    fi

    install -d -m 0755 /etc/lightdm/lightdm.conf.d
    cat >/etc/lightdm/lightdm.conf.d/10-vetro.conf <<'CONF'
[Seat:*]
autologin-user=vetro
autologin-session=xfce
CONF
    chmod 0644 /etc/lightdm/lightdm.conf.d/10-vetro.conf

    systemctl enable spice-vdagentd || true
    systemctl set-default graphical.target
}

run_desktop_phase() {
    if desktop_is_enabled; then
        run_phase desktop install_desktop
    else
        skip_phase desktop
    fi
}

record_boot_analysis() {
    local label="$1"
    local blame_file
    echo "SYSTEMD-ANALYZE:${label}"
    systemd-analyze || true
    blame_file="$(mktemp)"
    if systemd-analyze blame >"${blame_file}" 2>&1; then
        head -20 "${blame_file}"
    else
        cat "${blame_file}"
    fi
    rm -f "${blame_file}"
}

disable_and_mask_timer() {
    local unit="$1"
    local listing
    listing="$(systemctl list-unit-files "${unit}" --no-legend --no-pager 2>/dev/null || true)"
    if [[ -z "${listing}" ]]; then
        echo "${unit} not present; skipping"
        return
    fi
    if [[ "$(systemctl is-enabled "${unit}" 2>/dev/null || true)" == "masked" ]]; then
        echo "${unit} already masked"
        return
    fi

    systemctl disable --now "${unit}" || true
    systemctl mask "${unit}"
}

prune_boot() {
    local unit
    record_boot_analysis BEFORE

    if [[ ! -e /etc/cloud/cloud-init.disabled ]]; then
        touch /etc/cloud/cloud-init.disabled
    fi
    for unit in "${PRUNED_TIMERS[@]}"; do
        disable_and_mask_timer "${unit}"
    done

    # Debian 13 mounts /tmp as a tmpfs capped at half of RAM (2 GB here),
    # which package managers exhaust mid-install (ENOSPC) while the ext4
    # disk sits empty. Put /tmp on the disk: that is where the space is,
    # and fast ext4 I/O is the point of this VM. Applies from the next boot.
    if [[ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" != "masked" ]]; then
        systemctl mask tmp.mount
    fi

    # Keep fstrim.timer enabled: discard keeps the sparse host disk small (plan risk #7).
    record_boot_analysis AFTER
    echo "The true boot-time delta will be visible on the next boot."
}

update_claude() {
    DEBIAN_FRONTEND=noninteractive apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade claude-code
}

update_codex() {
    npm install -g @openai/codex@latest
}

update_grok() {
    sudo -u vetro bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash'
    ensure_grok_paths
    grok_is_installed
}

run_custom_phase() {
    local rc
    if [[ ! -f "${CUSTOM_SCRIPT}" ]]; then
        return
    fi
    if phase_is_done custom || phase_is_skipped custom || phase_is_failed custom; then
        return
    fi

    current_phase="custom"
    append_marker "PHASE:custom:START"
    : >"${CUSTOM_SCRIPT_LOG}"
    chmod 0644 "${CUSTOM_SCRIPT_LOG}"

    trap - ERR
    set +e
    sudo -u vetro bash -c 'cd /home/vetro && exec /usr/local/lib/vetro/custom-setup.sh' \
        >>"${CUSTOM_SCRIPT_LOG}" 2>&1
    rc=$?
    set -e
    trap on_error ERR

    if [[ "${rc}" -eq 0 ]]; then
        append_marker "PHASE:custom:DONE"
    else
        append_marker "PHASE:custom:FAIL rc=${rc}"
    fi
    current_phase="all"
}

load_selected_agents
ensure_vsock_ssh_bridge
ensure_vsock_port_bridge
ensure_guest_hooks
ensure_portwatch
ensure_vsock_host_bridge

if [[ "${mode}" == "update-agent" ]]; then
    agent="${2}"
    if ! is_known_agent "${agent}"; then
        echo "unknown agent: ${agent}"
        echo "usage: provision.sh update-agent {claude|codex|grok}"
        false
    fi
    current_phase="update-${agent}"
    run_update_phase "update-${agent}" "update_${agent}"
    append_marker "PHASE:update:DONE"
    exit 0
fi

if [[ "${mode}" == "update-agents" ]]; then
    run_selected_update_phase claude update_claude
    run_selected_update_phase codex update_codex
    run_selected_update_phase grok update_grok
    append_marker "PHASE:update:DONE"
    exit 0
fi

# Explicit post-provision enablement: install XFCE now regardless of
# desktop.conf (cloud-init is disabled after first boot). Hardware attaches
# on the next restart.
if [[ "${mode}" == "desktop" ]]; then
    if ! phase_is_done desktop; then
        current_phase="desktop"
        append_marker "PHASE:desktop:START"
        install_desktop
        append_marker "PHASE:desktop:DONE"
        current_phase="all"
    fi
    exit 0
fi

if provisioning_is_complete; then
    if ! phase_is_done all; then
        append_marker "PHASE:all:DONE"
    fi
    exit 0
fi

run_phase apt-base install_apt_base
run_phase node install_node
run_selected_agent_phase claude install_claude
run_selected_agent_phase codex install_codex
run_selected_agent_phase grok install_grok
run_phase workdir create_work_directory
run_desktop_phase
run_phase prune prune_boot
run_custom_phase

append_marker "PHASE:all:DONE"
