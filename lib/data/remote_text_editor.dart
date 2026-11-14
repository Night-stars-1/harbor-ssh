import 'dart:convert';
import 'dart:typed_data';

import '../domain/remote_file.dart';
import 'remote_replace.dart';

/// Upper bound for remote text files the editor will open or write.
const int remoteTextMaxBytes = 1 << 20; // 1 MiB

/// Reads and writes remote text files over an existing [RemoteFileSystem].
///
/// Only plain, non-link files are supported. Writing never truncates the
/// original in place: the edit is staged in an exclusive temporary file, the
/// original is moved aside, and the staged file is published with a rename so
/// the original bytes survive any failure short of a lost rename reply.
class RemoteTextEditor {
  RemoteTextEditor(this.files);

  /// Largest file (in bytes) that [load] and [save] accept.
  static const int maxBytes = remoteTextMaxBytes;

  final RemoteFileSystem files;

  /// Set when the last successful [save] could not delete its temporary
  /// backup; the path still holds the pre-save contents for manual recovery.
  String? leftoverBackupPath;

  /// Loads [file] as strict UTF-8 text.
  ///
  /// Throws a [StateError] for directories, links, oversized content, embedded
  /// NUL bytes or invalid UTF-8. Throws [TransferCancelled] when [cancellation]
  /// fires; the remote file is never modified.
  Future<String> load(
    RemoteFile file, {
    TransferCancellation? cancellation,
  }) async {
    _requirePlainFile(file);
    if (file.size != null && file.size! > maxBytes) {
      throw StateError('文件过大，无法编辑（上限 1 MiB）');
    }
    final bytes = await _read(file.path, cancellation: cancellation);
    return _decode(bytes);
  }

  /// Writes [edited] to [file] after confirming it still holds [original].
  ///
  /// Publishing goes through [replaceRemoteFile], so any failure leaves the
  /// original in place and cancelling before the publish changes nothing.
  Future<void> save(
    RemoteFile file,
    String original,
    String edited, {
    TransferCancellation? cancellation,
  }) async {
    _requirePlainFile(file);
    if (edited.contains('\x00')) {
      throw StateError('内容包含 NUL 字符，无法保存为文本');
    }
    final encoded = Uint8List.fromList(utf8.encode(edited));
    if (encoded.length > maxBytes) {
      throw StateError('编辑内容过大，无法保存（上限 1 MiB）');
    }
    leftoverBackupPath = null;
    leftoverBackupPath = await replaceRemoteFile(
      files,
      file.path,
      Stream<Uint8List>.value(encoded),
      cancellation: cancellation,
      verify: () =>
          _verifyUnchanged(file, original, cancellation: cancellation),
    );
  }

  Future<void> _verifyUnchanged(
    RemoteFile file,
    String original, {
    TransferCancellation? cancellation,
  }) async {
    final current = await statRemoteEntry(files, file.path);
    if (current == null) {
      throw StateError('远程文件已不存在，请重新打开');
    }
    if (current.isDirectory || current.isLink) {
      throw StateError('仅支持编辑普通文件');
    }
    if (file.size != null &&
        current.size != null &&
        current.size != file.size) {
      throw StateError('远程文件已被外部修改，请重新打开后再编辑');
    }
    final bytes = await _read(file.path, cancellation: cancellation);
    if (_decode(bytes) != original) {
      throw StateError('远程文件已被外部修改，请重新打开后再编辑');
    }
  }

  Future<Uint8List> _read(
    String path, {
    TransferCancellation? cancellation,
  }) async {
    final token = cancellation ?? TransferCancellation();
    final builder = BytesBuilder(copy: false);
    await files.download(
      path,
      (chunk) async {
        token.check();
        if (builder.length + chunk.length > maxBytes) {
          token.cancel();
          throw StateError('文件过大，无法编辑（上限 1 MiB）');
        }
        builder.add(chunk);
      },
      cancellation: token,
      onProgress: (_) {},
    );
    return builder.takeBytes();
  }

  String _decode(Uint8List bytes) {
    if (bytes.contains(0)) {
      throw StateError('文件包含 NUL 字符，不是可编辑的文本');
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw StateError('文件不是有效的 UTF-8 文本');
    }
  }

  void _requirePlainFile(RemoteFile file) {
    if (file.isDirectory) throw StateError('不能编辑目录');
    if (file.isLink) throw StateError('不能编辑符号链接文件');
  }
}
