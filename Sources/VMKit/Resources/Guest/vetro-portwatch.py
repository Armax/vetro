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
