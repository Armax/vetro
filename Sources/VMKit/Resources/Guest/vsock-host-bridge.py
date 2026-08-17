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
