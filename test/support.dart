import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/domain/host.dart';

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('disk unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

HostRepository memoryRepository() =>
    HostRepository(preferences: MemoryStore(), secrets: MemoryStore());
const testHost = Host(
  id: 'host-1',
  name: '开发服务器',
  address: 'dev.example.com',
  username: 'deploy',
  group: '开发',
);
