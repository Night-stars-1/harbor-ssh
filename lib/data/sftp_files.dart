import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../domain/remote_file.dart';
import 'public_key_install.dart';

/// Each operation owns its channel, independently of the terminal/completion.
class SftpFiles implements RemoteFileSystem {
  SftpFiles(this.openChannel);
  final Future<SftpClient> Function() openChannel;
  static const _timeout = Duration(seconds: 20);

  /// Permission bits for `~/.ssh` (octal 0700, as Dart has no octal literal).
  static const _sshDirectoryMode = 0x1c0;

  /// Permission bits for `authorized_keys` (octal 0600).
  static const _authorizedKeysMode = 0x180;

  /// Largest `authorized_keys` this client will read or extend. Anything
  /// bigger is refused instead of loaded into memory.
  static const _authorizedKeysLimit = 4 * 1024 * 1024;

  /// SFTP servers only report permissions through the attribute flags, and
  /// `open` cannot carry them, so these are applied with `setStat`.
  static final _sshDirectoryAttrs = SftpFileAttrs(
    mode: SftpFileMode.value(_sshDirectoryMode),
  );
  static final _authorizedKeysAttrs = SftpFileAttrs(
    mode: SftpFileMode.value(_authorizedKeysMode),
  );

  Future<T> _run<T>(Future<T> Function(SftpClient) action) async {
    final opening = openChannel();
    late SftpClient client;
    try {
      client = await opening.timeout(_timeout);
    } on TimeoutException {
      unawaited(
        opening
            .then((lateClient) => lateClient.close())
            .catchError((Object _) {}),
      );
      rethrow;
    }
    try {
      return await action(client);
    } finally {
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  @override
  Future<RemoteDirectory> browse(String path) => _run((client) async {
    if (path == '~' || path.startsWith('~/')) {
      final home = await client.absolute('.').timeout(_timeout);
      path = '$home${path.substring(1)}';
    }
    final absolute = await client.absolute(path).timeout(_timeout);
    final names = await client.listdir(absolute).timeout(_timeout);
    final entries = <RemoteFile>[];
    for (final name in names) {
      if (name.filename == '.' ||
          name.filename == '..' ||
          name.filename.contains('/') ||
          name.filename.contains('\x00')) {
        continue;
      }
      final fullPath = remoteChild(absolute, name.filename);
      var attrs = name.attr;
      if (attrs.isSymbolicLink) {
        try {
          attrs = await client.stat(fullPath).timeout(_timeout);
        } catch (_) {}
      }
      entries.add(
        RemoteFile(
          name: name.filename,
          path: fullPath,
          isDirectory: attrs.isDirectory,
          isLink: name.attr.isSymbolicLink,
          size: attrs.size,
          modified: attrs.modifyTime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return RemoteDirectory(absolute, entries);
  });

  @override
  String childPath(String directory, String name) =>
      remoteChild(directory, name);

  @override
  Future<void> createDirectory(String path) =>
      _run((client) => client.mkdir(path).timeout(_timeout));

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) =>
      _run((client) => _deleteDirectory(client, path, recursive: recursive));

  Future<void> _deleteDirectory(
    SftpClient client,
    String path, {
    required bool recursive,
  }) async {
    final current = await client
        .stat(path, followLink: false)
        .timeout(_timeout);
    if (current.isSymbolicLink || !current.isDirectory) {
      await client.remove(path).timeout(_timeout);
      return;
    }
    if (recursive) {
      final entries = await client.listdir(path).timeout(_timeout);
      for (final entry in entries) {
        if (entry.filename == '.' || entry.filename == '..') continue;
        if (entry.filename.contains('/') || entry.filename.contains('\x00')) {
          throw const FormatException('服务器返回了无效文件名');
        }
        final child = remoteChild(path, entry.filename);
        final childAttrs = await client
            .stat(child, followLink: false)
            .timeout(_timeout);
        if (childAttrs.isDirectory && !childAttrs.isSymbolicLink) {
          await _deleteDirectory(client, child, recursive: true);
        } else {
          await client.remove(child).timeout(_timeout);
        }
      }
    }
    await client.rmdir(path).timeout(_timeout);
  }

  @override
  Future<void> renameExclusive(String oldPath, String newPath) async {
    try {
      await _run((client) async {
        final handshake = await client.handshake.timeout(_timeout);
        final posixRename = handshake.extensions.remove(
          'posix-rename@openssh.com',
        );
        try {
          await client.rename(oldPath, newPath).timeout(_timeout);
        } finally {
          if (posixRename != null) {
            handshake.extensions['posix-rename@openssh.com'] = posixRename;
          }
        }
      });
    } catch (error, stack) {
      if (error is! TimeoutException && error is! SftpAbortError) {
        Error.throwWithStackTrace(error, stack);
      }
      try {
        final state = await _run((client) async {
          Future<bool> exists(String path) async {
            try {
              await client.stat(path, followLink: false).timeout(_timeout);
              return true;
            } on SftpStatusError catch (status) {
              if (status.code == SftpStatusCode.noSuchFile) return false;
              rethrow;
            }
          }

          return (old: await exists(oldPath), next: await exists(newPath));
        });
        if (!state.old && state.next) return;
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) => _run((client) async {
    cancellation.check();
    // Exclusive creation also prevents overwriting symlinks or a file that
    // appeared after the directory listing was loaded.
    SftpFile? file;
    var complete = false;
    try {
      file = await client
          .open(
            path,
            mode:
                SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive,
          )
          .timeout(_timeout);
      var offset = 0;
      await for (final chunk in source.timeout(_timeout)) {
        cancellation.check();
        await file.writeBytes(chunk, offset: offset).timeout(_timeout);
        offset += chunk.length;
        onProgress(offset);
      }
      cancellation.check();
      await file.close().timeout(_timeout);
      complete = true;
    } finally {
      if (file != null && !complete) {
        try {
          await file.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await client.remove(path).timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
  });

  @override
  Future<void> deleteFile(String path) =>
      _run((client) => client.remove(path).timeout(_timeout));

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) => _run((client) async {
    cancellation.check();
    final file = await client.open(path).timeout(_timeout);
    try {
      var count = 0;
      await for (final chunk in file.read().timeout(_timeout)) {
        cancellation.check();
        await write(chunk);
        count += chunk.length;
        onProgress(count);
      }
      cancellation.check();
    } finally {
      try {
        await file.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  });

  /// Installs [publicKey] as an entry in the login account's
  /// `~/.ssh/authorized_keys` through this operation's own SFTP channel.
  ///
  /// Returns true when the key was appended, false when the very same key (the
  /// same algorithm and base64 body, whatever its comment) was already there.
  /// Existing entries are never overwritten: the file is only ever opened for
  /// append, a missing final newline is completed first, and `~/.ssh` (0700)
  /// plus `authorized_keys` (0600) are confirmed before a key byte is sent —
  /// also when the key turns out to be present already. A server that will not
  /// confirm those exact permissions stops the install instead of being
  /// reported as a success. Success is only reported after reading the file
  /// back and finding the key.
  ///
  /// Throws a [FormatException] when [publicKey] is not one valid OpenSSH line
  /// (nothing is sent in that case) and a [PublicKeyInstallFailure] for every
  /// other problem; `unknown` is set when a write or a create may have landed
  /// without an answer, in which case running the call again is safe: a key
  /// that is already present is recognised and not appended twice.
  Future<bool> installAuthorizedKey(String publicKey) => _run((client) async {
    final key = parseOpenSshPublicKey(publicKey);
    final home = await _absoluteHome(client);
    final directory = remoteChild(home, '.ssh');
    final path = remoteChild(directory, 'authorized_keys');
    final state = _AuthorizedKeyInstall();
    try {
      // Refusals raised before anything is created or written are definite
      // on their own; the catch below rolls back and reclassifies a
      // failure that happens after this call has touched the server.
      final directoryAttrs = await _lstat(client, directory);
      if (directoryAttrs == null) {
        await _mutating(
          state,
          () => client.mkdir(directory, _sshDirectoryAttrs).timeout(_timeout),
        );
        state.created.add((path: directory, directory: true));
        final created = await _lstat(client, directory);
        if (created == null || created.isSymbolicLink || !created.isDirectory) {
          throw const PublicKeyInstallFailure('服务器未按预期创建 ~/.ssh 目录');
        }
        // A server may ignore the attributes of a create, so the 0700 has
        // to be confirmed before the directory is used.
        await _ensureMode(
          client,
          directory,
          created,
          _sshDirectoryAttrs,
          _sshDirectoryMode,
          '~/.ssh',
        );
      } else {
        if (directoryAttrs.isSymbolicLink || !directoryAttrs.isDirectory) {
          throw const PublicKeyInstallFailure('~/.ssh 是符号链接或不是目录，已拒绝写入');
        }
        await _ensureMode(
          client,
          directory,
          directoryAttrs,
          _sshDirectoryAttrs,
          _sshDirectoryMode,
          '~/.ssh',
        );
      }
      final fileAttrs = await _lstat(client, path);
      if (fileAttrs == null) {
        await _createAuthorizedKeys(
          client,
          path,
          _keyPayload(null, key.line),
          state,
        );
      } else {
        if (fileAttrs.isSymbolicLink || !fileAttrs.isFile) {
          throw const PublicKeyInstallFailure(
            'authorized_keys 是符号链接或不是普通文件，已拒绝写入',
          );
        }
        final size = fileAttrs.size;
        if (size != null && size > _authorizedKeysLimit) {
          throw const PublicKeyInstallFailure('authorized_keys 超过 4 MiB，已拒绝处理');
        }
        // The size above is only what the server claims; the bounded read
        // confirms it before the file is judged to be a duplicate.
        final current = await _readAuthorizedKeys(client, path);
        if (current.length > _authorizedKeysLimit) {
          throw const PublicKeyInstallFailure('authorized_keys 超过 4 MiB，已拒绝处理');
        }
        // The permissions are fixed before the duplicate check, so a file
        // that already holds the key also converges on 0600 — and a server
        // that will not confirm them stops the install here.
        await _ensureMode(
          client,
          path,
          fileAttrs,
          _authorizedKeysAttrs,
          _authorizedKeysMode,
          'authorized_keys',
        );
        if (_containsKey(current, key)) return false;
        final payload = _keyPayload(current, key.line);
        if (current.length + payload.length > _authorizedKeysLimit) {
          throw const PublicKeyInstallFailure(
            '追加后 authorized_keys 将超过 4 MiB，已拒绝写入',
          );
        }
        await _appendAuthorizedKeys(client, path, payload, state);
      }
      await _verifyAuthorizedKeys(client, path, key);
      return true;
    } catch (error) {
      // A bad key, or a refusal raised before anything was created or
      // written, is already definite: hand it back unchanged.
      final untouched =
          state.created.isEmpty && !state.appended && !state.uncertain;
      if (error is FormatException) rethrow;
      if (error is PublicKeyInstallFailure && untouched) rethrow;
      // Anything else may have left a file or directory behind, so it is
      // rolled back and classified by what this call actually owns.
      final restored = await _rollback(client, state.created);
      // An appended entry cannot be taken back; a file this call created
      // with `O_EXCL` can, which is what `restored` reports. A create that
      // timed out may have landed without ever being tracked, so it stays
      // uncertain instead of being reported as a definite failure.
      final unknown = state.appended || state.uncertain || !restored;
      final reason = error is PublicKeyInstallFailure
          ? error.message
          : error is TimeoutException
          ? '服务器响应超时'
          : '$error';
      throw PublicKeyInstallFailure(
        unknown
            ? '公钥安装结果未知（$reason）'
            : error is PublicKeyInstallFailure
            ? error.message
            : '公钥安装失败（$reason）',
        unknown: unknown,
      );
    }
  });

  /// The login account's home directory, resolved by the server for the SFTP
  /// session. `~` is never expanded locally.
  Future<String> _absoluteHome(SftpClient client) async {
    final home = await client.absolute('.').timeout(_timeout);
    if (!home.startsWith('/') || home.contains('\x00') || home.length > 4096) {
      throw const PublicKeyInstallFailure('服务器返回了无效的家目录');
    }
    return home;
  }

  Future<SftpFileAttrs?> _lstat(SftpClient client, String path) async {
    try {
      return await client.stat(path, followLink: false).timeout(_timeout);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  /// Whether the server reports exactly [mode] for [attrs]. A mode the server
  /// does not report counts as unknown, never as confirmed.
  bool _hasPermissions(SftpFileAttrs? attrs, int mode) {
    final current = attrs?.mode?.value;
    return current != null && (current & 0xfff) == mode;
  }

  /// Requires [path] to carry exactly [mode] as reported by the server.
  ///
  /// The read is what makes the result trustworthy: a server that silently
  /// ignores `setStat`, or that reports no mode at all, must not be allowed to
  /// turn into a reported success while the file could be readable by others.
  Future<void> _confirmMode(
    SftpClient client,
    String path,
    int mode,
    String label,
  ) async {
    if (!_hasPermissions(await _lstat(client, path), mode)) {
      throw PublicKeyInstallFailure('$label 权限未能确认为 ${_octal(mode)}，已拒绝继续');
    }
  }

  /// Restores exactly [mode] on [path] and confirms the change took effect.
  /// [current] is an already-read view of the path, so an exact mode costs no
  /// extra round trip.
  Future<void> _ensureMode(
    SftpClient client,
    String path,
    SftpFileAttrs? current,
    SftpFileAttrs attrs,
    int mode,
    String label,
  ) async {
    if (_hasPermissions(current, mode)) return;
    await client.setStat(path, attrs).timeout(_timeout);
    await _confirmMode(client, path, mode, label);
  }

  static String _octal(int mode) => mode.toRadixString(8).padLeft(4, '0');

  /// Appends the key to an existing file. `O_APPEND` makes the server place
  /// every write at the current end of the file, so no existing byte can be
  /// overwritten from here.
  Future<void> _appendAuthorizedKeys(
    SftpClient client,
    String path,
    Uint8List payload,
    _AuthorizedKeyInstall state,
  ) async {
    final file = await _openFile(
      client,
      path,
      SftpFileOpenMode.write | SftpFileOpenMode.append,
    );
    var complete = false;
    try {
      state.appended = true;
      await file.writeBytes(payload, offset: 0).timeout(_timeout);
      await file.close().timeout(_timeout);
      complete = true;
    } finally {
      if (!complete) await _closeQuietly(file);
    }
  }

  /// Runs a request that creates something on the server. Such a request can
  /// be executed even when its reply never arrives, so a timeout leaves state
  /// behind that this call can neither track nor roll back.
  Future<T> _mutating<T>(
    _AuthorizedKeyInstall state,
    Future<T> Function() request,
  ) async {
    try {
      return await request();
    } on TimeoutException {
      state.uncertain = true;
      rethrow;
    }
  }

  /// Creates a fresh `authorized_keys` holding only the key.
  Future<void> _createAuthorizedKeys(
    SftpClient client,
    String path,
    Uint8List payload,
    _AuthorizedKeyInstall state,
  ) async {
    final file = await _mutating(
      state,
      () => _openFile(
        client,
        path,
        SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive,
      ),
    );
    state.created.add((path: path, directory: false));
    var complete = false;
    try {
      // The permissions have to be in place before the first key byte: the
      // file exists from the moment the server honours the create, and there
      // is no way to hand permissions to `open`. The read that follows is what
      // makes the 0600 trustworthy rather than merely requested.
      await file.setStat(_authorizedKeysAttrs).timeout(_timeout);
      await _confirmMode(client, path, _authorizedKeysMode, 'authorized_keys');
      await file.writeBytes(payload, offset: 0).timeout(_timeout);
      await file.close().timeout(_timeout);
      complete = true;
    } finally {
      if (!complete) await _closeQuietly(file);
    }
  }

  /// Reads at most [_authorizedKeysLimit] + 1 bytes, so an oversized file is
  /// detected instead of loaded.
  Future<Uint8List> _readAuthorizedKeys(SftpClient client, String path) async {
    final file = await _openFile(client, path, SftpFileOpenMode.read);
    try {
      return await file
          .readBytes(length: _authorizedKeysLimit + 1)
          .timeout(_timeout);
    } finally {
      await _closeQuietly(file);
    }
  }

  /// Confirms the entry really is in the file now.
  Future<void> _verifyAuthorizedKeys(
    SftpClient client,
    String path,
    OpenSshPublicKey key,
  ) async {
    final content = await _readAuthorizedKeys(client, path);
    if (content.length > _authorizedKeysLimit || !_containsKey(content, key)) {
      throw const PublicKeyInstallFailure('写入后未能在 authorized_keys 中确认公钥');
    }
  }

  /// Whether [content] already holds the key with this algorithm and body.
  ///
  /// Only the key an entry actually declares counts: `#` comments are skipped,
  /// and text after a key is its comment, so a body that merely appears inside
  /// another entry's comment is not that entry.
  bool _containsKey(Uint8List content, OpenSshPublicKey key) {
    final text = utf8.decode(content, allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      final fields = findOpenSshKeyFields(line);
      if (fields != null &&
          fields.type == key.type &&
          fields.blob == key.blob) {
        return true;
      }
    }
    return false;
  }

  /// The bytes to append: the key line, prefixed by a newline when the existing
  /// content does not end with one, and always terminated by one.
  Uint8List _keyPayload(Uint8List? current, String line) {
    final separator =
        current != null && current.isNotEmpty && current.last != 0x0a;
    final encoded = utf8.encode(line);
    final payload = Uint8List(encoded.length + (separator ? 2 : 1));
    var offset = 0;
    if (separator) payload[offset++] = 0x0a;
    payload.setRange(offset, offset + encoded.length, encoded);
    payload[payload.length - 1] = 0x0a;
    return payload;
  }

  Future<SftpFile> _openFile(
    SftpClient client,
    String path,
    SftpFileOpenMode mode,
  ) async {
    final opening = client.open(path, mode: mode);
    try {
      return await opening.timeout(_timeout);
    } on TimeoutException {
      unawaited(
        opening.then((lateFile) => lateFile.close()).catchError((Object _) {}),
      );
      rethrow;
    }
  }

  Future<void> _closeQuietly(SftpFile file) async {
    try {
      await file.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Removes what this call created, the file before its directory. Reports
  /// whether the file is gone, since that is the only part that can hold key
  /// material; a leftover empty directory is not worth claiming a failure for.
  Future<bool> _rollback(
    SftpClient client,
    List<({String path, bool directory})> created,
  ) async {
    var removed = true;
    for (final entry in created.reversed) {
      final gone = await _removeQuietly(
        client,
        entry.path,
        directory: entry.directory,
      );
      if (!entry.directory) removed = gone;
    }
    return removed;
  }

  Future<bool> _removeQuietly(
    SftpClient client,
    String path, {
    required bool directory,
  }) async {
    try {
      if (directory) {
        await client.rmdir(path).timeout(const Duration(seconds: 5));
      } else {
        await client.remove(path).timeout(const Duration(seconds: 5));
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// What [SftpFiles.installAuthorizedKey] changed while it was running.
class _AuthorizedKeyInstall {
  /// Paths this call created, in creation order. Only these may be removed
  /// again on failure.
  final List<({String path, bool directory})> created = [];

  /// Set once a write was sent into a file that already existed: those bytes
  /// cannot be taken back, so a later failure leaves the file's content
  /// unknown. A file created here is tracked through [created] instead, since
  /// removing it restores the previous state exactly.
  bool appended = false;

  /// Set when a create request timed out, so it may have been executed even
  /// though nothing could be recorded or rolled back for it.
  bool uncertain = false;
}
