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
