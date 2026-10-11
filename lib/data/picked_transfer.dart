import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/remote_file.dart';
import 'local_files.dart';
import 'local_transfer.dart';
import 'resumable_copy.dart';

/// A phone/picker transfer keeps seekable data outside Android's write-only
/// document stream. Returning to the terminal and reconnecting does not lose
/// this task; export to the chosen document happens after the network copy.
class PickedTransfer {
  PickedTransfer._(
    this.cache,
    this.uploads,
    this.directory,
    this.download,
    this.endpoint,
  );
  final String endpoint;
  final Directory cache;
  final List<UploadFile>? uploads;
  final String? directory;
  final RemoteFile? download;
  final _jobs = <int, ResumableFileCopy>{};
  int completed = 0;
  bool discarding = false;
  String get name =>
      download?.name ?? uploads![completed.clamp(0, uploads!.length - 1)].name;
  int get transferred => _jobs[completed]?.transferred ?? 0;
  int? get total =>
      _jobs[completed]?.total ??
      download?.size ??
      (uploads == null
          ? null
          : uploads![completed.clamp(0, uploads!.length - 1)].size);

  static Future<PickedTransfer> upload(
    List<UploadFile> uploads,
    String directory, {
    required String endpoint,
    Directory? cacheDirectory,
  }) async => PickedTransfer._(
    await _cache(cacheDirectory),
    uploads,
    directory,
    null,
    endpoint,
  );
  static Future<PickedTransfer> downloading(
    RemoteFile file, {
    required String endpoint,
    Directory? cacheDirectory,
  }) async => PickedTransfer._(
    await _cache(cacheDirectory),
    null,
    null,
    file,
    endpoint,
  );
  static Future<Directory> _cache(Directory? directory) async =>
      (directory ?? await getTemporaryDirectory()).createTemp(
        'harbor-transfer-',
      );

  Future<void> run(
    ResumableFileSystem remote,
    TransferCancellation cancellation, {
    required void Function(String name, int? total, int offset) onFile,
    required void Function(int) onProgress,
    required LocalTransfer picker,
  }) async {
    if (discarding) throw StateError('缓存清理尚未完成，请再次放弃传输');
    final local = LocalFiles(cache.path);
    if (download != null) {
      final file = download!;
      final job = _jobs.putIfAbsent(
        0,
        () => ResumableFileCopy(
          source: remote,
          destination: local,
          sourcePath: file.path,
          destinationPath: local.childPath(local.root, 'download'),
        ),
      );
      job.rebind(remote, local);
      onFile('下载 ${file.name}', job.total ?? file.size, job.transferred);
      await job.run(cancellation, onProgress);
      cancellation.check();
      onFile('保存 ${file.name}', job.total, 0);
      final target = await picker.pickDownload(file.name);
      if (target == null) throw TransferCancelled();
      var finished = false;
      try {
        await local.download(
          job.destinationPath,
          target.write,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        cancellation.check();
        await target.finish();
        finished = true;
      } finally {
        if (!finished) await target.abort();
      }
    } else {
      while (completed < uploads!.length) {
        cancellation.check();
        final index = completed;
        final upload = uploads![index];
        var job = _jobs[index];
        onFile(
          '上传 ${upload.name} · ${index + 1}/${uploads!.length}',
          job?.total ?? upload.size,
          job?.transferred ?? 0,
        );
        if (job == null) {
          // SAF providers do not expose random access. Freeze a private local
          // source once, so retries neither reread the network nor mix versions.
          var sourcePath = upload.path;
          if (sourcePath == null) {
            sourcePath = local.childPath(local.root, 'upload-$index');
            final file = File(sourcePath);
            final output = await file.open(mode: FileMode.write);
            var prepared = false;
            try {
              await for (final bytes in upload.openRead()) {
                cancellation.check();
                await output.writeFrom(bytes);
              }
              cancellation.check();
              await output.flush();
              prepared = true;
            } finally {
              await output.close();
              if (!prepared) await file.delete();
            }
          }
          job = ResumableFileCopy(
            source: local,
            destination: remote,
            sourcePath: sourcePath,
            destinationPath: remote.childPath(directory!, upload.name),
          );
          _jobs[index] = job;
        }
        job.rebind(local, remote);
        await job.run(cancellation, onProgress);
        completed++;
      }
    }
    await cache.delete(recursive: true);
  }

  Future<void> discard(ResumableFileSystem remote) async {
    discarding = true;
    final local = LocalFiles(cache.path);
    for (final job in _jobs.values) {
      job.rebind(
        download == null ? local : remote,
        download == null ? remote : local,
      );
      await job.discard();
    }
    if (await cache.exists()) await cache.delete(recursive: true);
  }
}
