class RemoteSyncData {
  const RemoteSyncData({this.content, this.version});
  final String? content, version;
}

abstract class SyncBackend {
  Future<void> test();
  Future<RemoteSyncData> read();

  /// Returns a newly allocated remote ID, if one was created.
  Future<String?> write(String encrypted, RemoteSyncData previous);
}
