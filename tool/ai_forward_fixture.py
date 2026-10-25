"""Loopback SSH server with real direct-tcpip forwarding.

Used only by the AI runtime integration test. The server authenticates with a
fixed test password, accepts direct-tcpip channels to one local HTTP target and
serves a shell channel so reconnects work. No host command is ever executed.
"""

import json
import logging
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)


class TargetHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = b"forwarded-ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, *_args):
        pass


target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
target_port = target.server_address[1]
threading.Thread(target=target.serve_forever, daemon=True).start()

host_key = paramiko.RSAKey.generate(2048)


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.destinations = {}
        self.lock = threading.Lock()

    def get_allowed_auths(self, _username):
        return "password"

    def check_auth_password(self, username, password):
        if username == "tester" and password == "fixture-password":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind, _chanid):
        if kind in ("session", "direct-tcpip"):
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, _origin, destination):
        host, port = destination
        if host in ("127.0.0.1", "localhost", "::1") and int(port) == target_port:
            with self.lock:
                self.destinations[chanid] = (host, int(port))
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(
        self, _channel, _term, _width, _height, _pixelwidth, _pixelheight, _modes
    ):
        return True

    def check_channel_shell_request(self, _channel):
        return True


def forward(channel):
    try:
        sock = socket.create_connection(("127.0.0.1", target_port), timeout=10)
    except OSError:
        channel.close()
        return

    def client_to_target():
        try:
            while True:
                data = channel.recv(65536)
                if not data:
                    break
                sock.sendall(data)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def target_to_client():
        try:
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                channel.sendall(data)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            try:
                sock.close()
            except OSError:
                pass
            try:
                channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass

    threading.Thread(target=client_to_target, daemon=True).start()
    threading.Thread(target=target_to_client, daemon=True).start()


def shell(channel):
    try:
        channel.sendall(b"$ ")
        while True:
            data = channel.recv(4096)
            if not data:
                break
            channel.sendall(b"ECHO=" + data)
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        try:
            channel.close()
        except (EOFError, OSError, paramiko.SSHException):
            pass


def serve(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    server = Server()
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(0.2)
            if channel is None:
                continue
            with server.lock:
                is_forward = channel.get_id() in server.destinations
            threading.Thread(
                target=forward if is_forward else shell,
                args=(channel,),
                daemon=True,
            ).start()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(10)
print(
    json.dumps(
        {
            "port": listener.getsockname()[1],
            "targetPort": target_port,
        }
    ),
    flush=True,
)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
