"""Loopback-only SSH protocol fixture. No OS commands are executed."""
import io
import json
import logging
import os
import posixpath
import stat
from pathlib import Path
import socket
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".tools" / "python"))
import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
host_key = paramiko.RSAKey.generate(2048)
client_key = paramiko.RSAKey.generate(2048)
key_text = io.StringIO()
client_key.write_private_key(key_text, password="fixture-passphrase")

class HistoryHandle(paramiko.SFTPHandle):
    def __init__(self, data):
        super().__init__()
        self.data = data

    def read(self, offset, length):
        return self.data[offset:offset + length]

class TransferHandle(paramiko.SFTPHandle):
    def __init__(self, files, path, flags):
        super().__init__(flags)
        self.files, self.path = files, path

    def stat(self):
        attr = paramiko.SFTPAttributes()
        attr.st_mode = stat.S_IFREG | 0o644
        attr.st_size = len(self.files[self.path])
        return attr

    def read(self, offset, length):
        return self.files[self.path][offset:offset + length]

    def write(self, offset, data):
        if self.path.endswith('/write-fail'):
            return paramiko.SFTP_PERMISSION_DENIED
        previous = self.files[self.path]
        self.files[self.path] = previous[:offset].ljust(offset, b'\x00') + data + previous[offset + len(data):]
        return paramiko.SFTP_OK

class DirectoryFixture(paramiko.SFTPServerInterface):
    """A virtual directory tree; never accesses the host filesystem."""
    entries = {
        "/": stat.S_IFDIR | 0o755,
        "/home": stat.S_IFDIR | 0o755,
        "/home/tester": stat.S_IFDIR | 0o755,
        "/home/tester/docs": stat.S_IFDIR | 0o755,
        "/home/tester/my dir": stat.S_IFDIR | 0o755,
        "/home/tester/readme.txt": stat.S_IFREG | 0o644,
        "/home/tester/linkdir": stat.S_IFLNK | 0o777,
    }
    files = {
        "/home/tester/readme.txt": b"Hello SFTP\n",
        "/home/tester/.bash_history": b"#1700000000\ngit status\n#1700000001\ngit log\n",
        "/home/tester/.zsh_history": b": 1700000002:0;docker ps\n",
    }

    def __init__(self, server, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        if not hasattr(server, 'file_entries'):
            server.file_entries = dict(type(self).entries)
            server.file_data = dict(type(self).files)
        self.entries, self.files = server.file_entries, server.file_data

    def open(self, path, flags, attr):
        path = self.canonicalize(path)
        if flags & os.O_CREAT:
            if path in self.files and flags & os.O_EXCL:
                return paramiko.SFTP_FAILURE
            if posixpath.dirname(path) not in self.entries:
                return paramiko.SFTP_NO_SUCH_FILE
            self.files.setdefault(path, b'')
            self.entries[path] = stat.S_IFREG | 0o644
        if path not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        return TransferHandle(self.files, path, flags)

    def mkdir(self, path, attr):
        path = self.canonicalize(path)
        if path in self.entries or posixpath.dirname(path) not in self.entries:
            return paramiko.SFTP_FAILURE
        self.entries[path] = stat.S_IFDIR | 0o755
        return paramiko.SFTP_OK

    def rmdir(self, path):
        path = self.canonicalize(path)
        if path not in self.entries or not stat.S_ISDIR(self.entries[path]):
            return paramiko.SFTP_NO_SUCH_FILE
        if any(posixpath.dirname(name) == path for name in self.entries if name != path):
            return paramiko.SFTP_FAILURE
        del self.entries[path]
        return paramiko.SFTP_OK

    def remove(self, path):
        path = self.canonicalize(path)
        if path not in self.files:
            return paramiko.SFTP_NO_SUCH_FILE
        del self.files[path]
        self.entries.pop(path, None)
        return paramiko.SFTP_OK

    def canonicalize(self, path):
        return posixpath.normpath(path if path.startswith("/") else "/home/tester/" + path)

    def list_folder(self, path):
        path = self.canonicalize(path)
        if path not in self.entries or not stat.S_ISDIR(self.entries[path]):
            return paramiko.SFTP_NO_SUCH_FILE
        result = []
        for name, mode in self.entries.items():
            if posixpath.dirname(name) == path:
                entry = paramiko.SFTPAttributes()
                entry.filename = posixpath.basename(name)
                entry.st_mode = mode
                entry.st_size = len(self.files.get(name, b''))
                entry.st_mtime = 1700000002
                result.append(entry)
        return result

    def stat(self, path):
        path = self.canonicalize(path)
        if path in self.files:
            entry = paramiko.SFTPAttributes()
            entry.st_mode = stat.S_IFREG | 0o600
            entry.st_size = len(self.files[path])
            entry.st_mtime = 1700000002
            return entry
        if path == "/home/tester/linkdir":
            path = "/home/tester/docs"
        if path not in self.entries:
            return paramiko.SFTP_NO_SUCH_FILE
        entry = paramiko.SFTPAttributes()
        entry.st_mode = self.entries[path]
        return entry

    def lstat(self, path):
        path = self.canonicalize(path)
        if path not in self.entries:
            return paramiko.SFTP_NO_SUCH_FILE
        entry = paramiko.SFTPAttributes()
        entry.st_mode = self.entries[path]
        entry.st_size = len(self.files.get(path, b''))
        entry.st_mtime = 1700000002
        return entry

class Server(paramiko.ServerInterface):
    def __init__(self):
        self.shell_ready = threading.Event()
        self.shell_channel = None
        self.width, self.height = 80, 24
        self.catalog_queries = 0
        self.metrics_queries = 0
    def get_allowed_auths(self, username):
        return "password,publickey"
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("tester", "fixture-password") else paramiko.AUTH_FAILED
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "tester" and key == client_key else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.width, self.height = width, height
        return True
    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        self.width, self.height = width, height
        return True
    def check_channel_shell_request(self, channel):
        self.shell_channel = channel
        self.shell_ready.set()
        return True
    def check_channel_exec_request(self, channel, command):
        if command in (b"harbor-ai-fixture-success", b"harbor-ai-fixture-fail", b"harbor-ai-fixture-large", b"harbor-ai-fixture-wait"):
            def ai_reply():
                try:
                    # Virtual AI results only; never run commands on the host.
                    channel.sendall("AI 测试输出\n".encode())
                    if command == b"harbor-ai-fixture-wait":
                        return  # Remains open until the client cancels the channel.
                    if command == b"harbor-ai-fixture-large":
                        channel.sendall(b"x" * 40000)
                    if command == b"harbor-ai-fixture-fail":
                        channel.sendall_stderr(b"fixture error\n")
                    channel.send_exit_status(7 if command == b"harbor-ai-fixture-fail" else 0)
                    channel.close()
                except (EOFError, OSError, paramiko.SSHException):
                    pass
            threading.Timer(0.02, ai_reply).start()
            return True
        if command.startswith(b"sh -c ") and b"__HARBOR_REMOTE_METRICS_BEGIN__" in command:
            self.metrics_queries += 1
            count = self.metrics_queries - 1
            def metrics_reply():
                try:
                    # Fixed virtual Linux procfs results; never run a client command.
                    channel.sendall((
                        "login banner\n__HARBOR_REMOTE_METRICS_BEGIN__\n"
                        "os Linux\n"
                        f"cpu {100 + 50 * count} 0 {50 + 25 * count} {1000 + 10 * count} 10 0 0 0\n"
                        f"core cpu0 {100 + 50 * count} 0 {50 + 25 * count} {1000 + 10 * count} 10 0 0 0\n"
                        f"core cpu1 {100 + 25 * count} 0 {50 + 10 * count} {1000 + 50 * count} 10 0 0 0\n"
                        f"uptime {12345.67 + 5 * count}\n"
                        "memtotal 16316420 kB\nmemavail 8000000 kB\n"
                        "iface eth0\n"
                        f"net {1000000 + 500000 * count} {2000000 + 250000 * count}\n"
                        "processes-ok\nprocess 123 65536 postgres\nprocess 456 32768 node worker\n"
                        "disks-ok\n"
                        "df tmpfs tmpfs 4096 128 3968 4% /run\n"
                        "df overlay overlay 10240000 4096000 6144000 40% /var/lib/docker/overlay2/test/merged\n"
                        "df /dev/sdb1 ext4 20480000 10240000 9216000 53% /data volume\n"
                        "df /dev/sda1 ext4 10240000 4096000 6144000 40% /\n"
                        "__HARBOR_REMOTE_METRICS_END__\n"
                    ).encode())
                    channel.send_exit_status(0)
                    channel.close()
                except (EOFError, OSError, paramiko.SSHException):
                    pass
            threading.Timer(0.02, metrics_reply).start()
            return True
        if not command.startswith(b"sh -c ") or b"__HARBOR_COMMANDS_BEGIN__" not in command:
            return False
        self.catalog_queries += 1
        def reply():
            try:
                # Fixed virtual results; never execute received shell code.
                channel.sendall(b"banner\n__HARBOR_COMMANDS_BEGIN__\ndocker\ndocker-compose\ndocker\ncd\ngit\nbad;command\n__HARBOR_COMMANDS_END__\n")
                channel.send_exit_status(0)
                channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass
        threading.Timer(0.02, reply).start()
        return True

def serve(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    transport.set_subsystem_handler("sftp", paramiko.SFTPServer, DirectoryFixture)
    server = Server()
    try:
        transport.start_server(server=server)
        while transport.is_active() and not server.shell_ready.wait(0.1):
            pass
        channel = server.shell_channel
        if channel is None:
            return
        greeting = "测试 connected\r\n$ ".encode()
        channel.sendall(greeting[:1])
        channel.sendall(greeting[1:])
        pending = b""
        while transport.is_active():
            data = channel.recv(4096)
            if not data:
                break
            if b"\x03" in data:
                channel.sendall(b"interrupted\r\n$ ")
                data = data.replace(b"\x03", b"")
            pending += data.replace(b"\r", b"\n")
            while b"\n" in pending:
                command, pending = pending.split(b"\n", 1)
                if command == b"exit":
                    channel.sendall(b"FINAL-OUTPUT\r\n")
                    channel.send_exit_status(0)
                    channel.close()
                    return
                if command == b"size":
                    channel.sendall(f"SIZE={server.width}x{server.height}\r\n$ ".encode())
                elif command == b"catalog-count":
                    channel.sendall(f"CATALOGS={server.catalog_queries}\r\n$ ".encode())
                else:
                    channel.sendall(b"ECHO=" + command + b"\r\n$ ")
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()

listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(10)
print(json.dumps({"port": listener.getsockname()[1], "privateKey": key_text.getvalue()}), flush=True)
while True:
    client, _ = listener.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
