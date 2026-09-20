import 'dart:convert';

import '../domain/host.dart';
import '../domain/sync_snapshot.dart';
import 'host_repository.dart';

class SyncStorage {
  SyncStorage(this.repository);
  final HostRepository repository;
  static const _journal = 'harbor.sync.pending.v1';

  Future<SyncSnapshot> capture() async {
    final records = <String, Map<String, dynamic>>{};
    for (final host in await repository.loadHosts()) {
      records['host:${host.id}'] = {
        'data': host.toJson(),
        'secret': (await repository.credentials(host.id))?.toJson(),
      };
    }
    for (final user in await repository.loadUsers()) {
      records['key:${user.id}'] = {
        'data': user.toJson(),
        'secret': (await repository.userCredentials(user.id))?.toJson(),
      };
    }
    return SyncSnapshot(records);
  }

  Future<void> recover() async {
    final pending = await repository.secrets.read(_journal);
    if (pending == null) return;
    final journal = jsonDecode(pending) as Map<String, dynamic>;
    final before = SyncSnapshot.decode(journal['before'] as String);
    final incoming = SyncSnapshot.decode(journal['incoming'] as String);
    await _write(before, incoming);
    await repository.secrets.delete(_journal);
  }

  Future<void> apply(SyncSnapshot snapshot) async {
    final before = await capture();
    await repository.secrets.write(
      _journal,
      jsonEncode({'before': before.encode(), 'incoming': snapshot.encode()}),
    );
    try {
      await _write(snapshot, before);
      await repository.secrets.delete(_journal);
    } catch (_) {
      // Leave the encrypted-system-store journal for startup recovery if rollback fails.
      await recover();
      rethrow;
    }
  }

  Future<void> _write(SyncSnapshot next, SyncSnapshot previous) async {
    final hosts = <Host>[];
    final users = <SshUser>[];
    for (final entry in next.records.entries) {
      final data = Map<String, dynamic>.from(entry.value['data'] as Map);
      final value = entry.value['secret'];
      final secret = value == null
          ? null
          : Credentials.fromJson(Map<String, dynamic>.from(value as Map));
      if (entry.key.startsWith('host:')) {
        final host = Host.fromJson(data);
        hosts.add(host);
        await repository.saveCredentials(host.id, secret);
      } else {
        final user = SshUser.fromJson(data);
        users.add(user);
        await repository.saveUserCredentials(user.id, secret);
      }
    }
    await repository.saveHosts(hosts);
    await repository.saveUsers(users);
    for (final id in previous.records.keys.where(
      (id) => !next.records.containsKey(id),
    )) {
      if (id.startsWith('host:')) {
        await repository.saveCredentials(id.substring(5), null);
      } else {
        await repository.saveUserCredentials(id.substring(4), null);
      }
    }
  }
}
