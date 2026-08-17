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
