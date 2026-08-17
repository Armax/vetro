#!/usr/bin/env python3

import json
import socket
import time


HOST_CID = 2
HOST_PORT = 1024
RETRY_SECONDS = 2


def primary_ipv4():
    """Return the IPv4 address selected by the guest's default route."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # A UDP connect selects a route without sending a packet.
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
        return address if address and not address.startswith("127.") else None
    except OSError:
        return None
    finally:
        probe.close()


def report(address):
    """Send one readiness record to the macOS host and close the connection."""
    connection = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        connection.settimeout(5)
        connection.connect((HOST_CID, HOST_PORT))
        record = json.dumps(
            {"ip": address, "ready": True}, separators=(",", ":")
        )
        connection.sendall((record + "\n").encode("utf-8"))
    finally:
        connection.close()


def main():
    """Keep reporting readiness so a restarted host can discover the guest."""
    while True:
        address = primary_ipv4()
        if address is not None:
            try:
                report(address)
            except OSError:
                pass
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
