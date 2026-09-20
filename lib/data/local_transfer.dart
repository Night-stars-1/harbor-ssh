import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

class UploadFile {
  const UploadFile(this.name, this.size, this.openRead);
  final String name;
  final int? size;
  final Stream<Uint8List> Function() openRead;
}

abstract interface class DownloadTarget {
  Future<void> write(Uint8List bytes);
  Future<void> finish();
  Future<void> abort();
}

abstract interface class LocalTransfer {
  Future<List<UploadFile>> pickUploads();
  Future<DownloadTarget?> pickDownload(String name);
}

class NativeLocalTransfer implements LocalTransfer {
  const NativeLocalTransfer();
  static const channel = MethodChannel('dev.harborssh/file_transfer');

  @override
  Future<List<UploadFile>> pickUploads() async {
    final picked = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
    return [
      for (final file in picked)
        UploadFile(file.name, await file.length(), file.readAsByteStream),
    ];
  }

  @override
  Future<DownloadTarget?> pickDownload(String name) async {
    final safeName = localFileName(name);
    if (Platform.isAndroid) {
      final created = await channel.invokeMethod<bool>('create', {
        'name': safeName,
      });
      return created == true ? _AndroidDownload() : null;
    }
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择下载文件夹');
    if (directory == null) return null;
    return createDiskDownload(directory, safeName);
  }

  static Future<DownloadTarget> createDiskDownload(
    String directory,
    String name,
  ) async {
    final safeName = localFileName(name);
    final destination = File('$directory${Platform.pathSeparator}$safeName');
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('下载文件夹中已有同名文件，请选择其他文件夹');
    }
    // A unique staging directory keeps interrupted downloads out of the final
    // filename and bounds memory regardless of remote file size.
    final staging = await Directory(directory).createTemp('.harbor-download-');
    return _DiskDownload(destination, staging, File('${staging.path}/data'));
  }
}

String localFileName(String name) {
  var result = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = 'download';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  return result;
}

class _DiskDownload implements DownloadTarget {
  _DiskDownload(this.destination, this.staging, this.temporary);
  final File destination, temporary;
  final Directory staging;
  RandomAccessFile? _output;
  @override
  Future<void> write(Uint8List bytes) async {
    final output = _output ??= await temporary.open(mode: FileMode.write);
    await output.writeFrom(bytes);
  }

  @override
  Future<void> finish() async {
    if (_output == null) await write(Uint8List(0));
    await _output!.flush();
    await _output!.close();
    _output = null;
    // Reserve the destination exclusively; never replace a file that appeared
    // while the download was in progress.
    await destination.create(exclusive: true);
    try {
      await temporary.rename(destination.path);
    } catch (_) {
      await destination.delete();
      rethrow;
    }
    await staging.delete();
  }

  @override
  Future<void> abort() async {
    await _output?.close();
    _output = null;
    if (await temporary.exists()) await temporary.delete();
    if (await staging.exists()) await staging.delete();
  }
}

class _AndroidDownload implements DownloadTarget {
  @override
  Future<void> write(Uint8List bytes) =>
      NativeLocalTransfer.channel.invokeMethod<void>('write', bytes);
  @override
  Future<void> finish() =>
      NativeLocalTransfer.channel.invokeMethod<void>('finish');
  @override
  Future<void> abort() =>
      NativeLocalTransfer.channel.invokeMethod<void>('abort');
}
