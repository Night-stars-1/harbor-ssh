"""Loopback-only SSH forwarding fixture; no user credentials or files are read."""
import json
import logging
import os
from pathlib import Path
import socket
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".tools" / "python"))
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


def bridge(left, right):
    def copy(source, target):
        try:
            while True:
                chunk = source.recv(65536)
                if not chunk:
                    break
                target.sendall(chunk)
            if isinstance(target, paramiko.Channel):
                target.shutdown_write()
            else:
                target.shutdown(socket.SHUT_WR)
        except (OSError, EOFError, paramiko.SSHException):
            left.close()
            right.close()
    thread = threading.Thread(target=copy, args=(left, right), daemon=True)
    thread.start()
    copy(right, left)
    thread.join(timeout=10)
    left.close()
    right.close()


class Transport(paramiko.Transport):
    def _parse_global_request(self, message):
        probe = paramiko.Message(message.asbytes())
        kind = probe.get_text()
        if kind == 'cancel-tcpip-forward' and self.server_object.reject_cancel:
            self.server_object.reject_cancel = False
            self._send_message(paramiko.Message(bytes([82])))
            return
        super()._parse_global_request(message)


class Server(paramiko.ServerInterface):
    def __init__(self, transport):
        self.transport = transport
        self.targets = {}
        self.listeners = {}
        self.reject_cancel = False

    def check_auth_password(self, username, password):
        self.reject_cancel = username == 'reject-once'
        return paramiko.AUTH_SUCCESSFUL if password == 'fixture-password' else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return 'publickey,password'

    def check_auth_publickey(self, username, key):
        expected = os.environ.get('HARBOR_FIXTURE_PUBLIC_KEY', '').split()
        accepted = username == 'tester' and len(expected) >= 2 and key.get_base64() == expected[1]
        return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

    def check_channel_direct_tcpip_request(self, channel_id, origin, destination):
        # This alias cannot resolve on the client. Only the gateway translates
        # it, proving that SSH jumps pass target names to the forwarding peer.
        if destination[0] == 'jump-fixture.invalid':
            destination = ('127.0.0.1', destination[1])
        if destination[0] not in ('127.0.0.1', 'localhost', '::1'):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.targets[channel_id] = destination
        return paramiko.OPEN_SUCCEEDED

    def check_port_forward_request(self, address, port):
        if address != '127.0.0.1':
            return False
        listener = socket.socket()
        try:
            listener.bind((address, port))
            listener.listen(16)
            listener.settimeout(0.2)
        except OSError:
            listener.close()
            return False
        assigned = listener.getsockname()[1]
        self.listeners[(address, assigned)] = listener

        def accept():
            while self.transport.is_active():
                try:
                    incoming, origin = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    channel = self.transport.open_forwarded_tcpip_channel(origin, (address, assigned))
                    threading.Thread(target=bridge, args=(incoming, channel), daemon=True).start()
                except (OSError, EOFError, paramiko.SSHException):
                    incoming.close()
        threading.Thread(target=accept, daemon=True).start()
        return assigned

    def cancel_port_forward_request(self, address, port):
        listener = self.listeners.pop((address, port), None)
        if listener:
            listener.close()


host_key = paramiko.RSAKey.generate(2048)


def serve(socket_):
    transport = Transport(socket_)
    transport.add_server_key(host_key)
    server = Server(transport)
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(0.2)
            if channel is None:
                continue
            target = server.targets.pop(channel.get_id(), None)
            if target is None:
                channel.close()
                continue
            try:
                outgoing = socket.create_connection(target, timeout=5)
                outgoing.settimeout(None)
                threading.Thread(target=bridge, args=(channel, outgoing), daemon=True).start()
            except OSError:
                channel.close()
    except (OSError, EOFError, paramiko.SSHException):
        pass
    finally:
        for listener in list(server.listeners.values()):
            listener.close()
        transport.close()


listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(16)
print(json.dumps({'port': listener.getsockname()[1]}), flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
