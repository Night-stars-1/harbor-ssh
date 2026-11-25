import 'dart:convert';

import '../domain/host.dart';
import '../domain/network_identity.dart';
import '../domain/port_forward.dart';
import '../domain/sync_snapshot.dart';
import 'host_repository.dart';

class SyncStorage {
  SyncStorage(this.repository);
  final HostRepository repository;
  static const _journal = 'harbor.sync.pending.v1';

  Future<SyncSnapshot> capture() async {
    final records = <String, Map<String, dynamic>>{};
    for (final host in await repository.loadHosts()) {
      records['host:${host.id}'] = SyncSnapshot.hostRecord(
        host,
        await repository.credentials(host.id),
      );
      // Rule definitions travel with their host; which rules run, and on
      // which actual port, stays on this device.
      for (final rule in await repository.loadPortForwards(host.id)) {
        records[SyncSnapshot.forwardId(host.id, rule.id)] =
            SyncSnapshot.forwardRecord(host.id, rule);
      }
    }
    for (final user in await repository.loadUsers()) {
      records['key:${user.id}'] = {
        'data': user.toJson(),
        'secret': (await repository.userCredentials(user.id))?.toJson(),
      };
    }
    // Only the identity definitions travel; which one this device uses stays
    // in the device-local [NetworkIdentities.activeId].
    final identities = await repository.loadNetworkIdentities();
    for (final identity in identities.identities) {
      records['identity:${identity.id}'] = {'data': identity.toJson()};
    }
    return SyncSnapshot(records);
  }

  Future<void> recover() async {
    final pending = await repository.secrets.read(_journal);
    if (pending == null) return;
    final journal = jsonDecode(pending) as Map<String, dynamic>;
    final before = SyncSnapshot.decode(journal['before'] as String);
    final incoming = SyncSnapshot.decode(journal['incoming'] as String);
    // Journals written before identities were synced carry no activeId; their
    // snapshots cannot express identity deletions, so leave the device's
    // definitions and selection untouched.
    final activeId = journal['activeId'];
    await _write(
      before,
      incoming,
      activeId: activeId as String?,
      writeIdentities: activeId is String,
    );
    await repository.secrets.delete(_journal);
  }

  Future<void> apply(SyncSnapshot snapshot) async {
    snapshot.requireCompletePrivateKeys();
    final activeId = (await repository.loadNetworkIdentities()).activeId;
    final before = await capture();
    await repository.secrets.write(
      _journal,
      jsonEncode({
        'before': before.encode(),
        'incoming': snapshot.encode(),
        // The active identity is device-local, so the rollback snapshot alone
        // cannot restore a selection that this apply removes.
        'activeId': activeId,
      }),
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

  Future<void> _write(
    SyncSnapshot next,
    SyncSnapshot previous, {
    String? activeId,
    bool writeIdentities = true,
  }) async {
    final hosts = <Host>[];
    final users = <SshUser>[];
    final identities = <String, NetworkIdentity>{};
    final forwards = <String, Map<String, PortForwardRule>>{};
    for (final entry in next.records.entries) {
      final data = Map<String, dynamic>.from(entry.value['data'] as Map);
      if (entry.key.startsWith('identity:')) {
        final identity = NetworkIdentity.fromJson(data);
        identities[identity.id] = identity;
        continue;
      }
      if (entry.key.startsWith('forward:')) {
        final rule = PortForwardRule.fromJson(data);
        (forwards[data['hostId'] as String] ??= {})[rule.id] = rule;
        continue;
      }
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
    // Keep this device's identity order and append newly synced identities.
    // [activeId] restores the journal's selection on rollback; otherwise the
    // local one is kept, and copyWith returns to the default identity when it
    // is no longer in the list.
    if (writeIdentities) {
      final local = await repository.loadNetworkIdentities();
      final ordered = <NetworkIdentity>[];
      for (final identity in local.identities) {
        final match = identities.remove(identity.id);
        if (match != null) ordered.add(match);
      }
      ordered.addAll(identities.values);
      await repository.saveNetworkIdentities(
        local.copyWith(identities: ordered, activeId: activeId),
      );
    }
    await repository.saveHosts(hosts);
    await repository.saveUsers(users);
    // Rewrite each host whose rules either side carries. Local order is kept
    // and newly synced rules are appended; rules of a host that is not in
    // [next] are removed with it.
    final hostIds = hosts.map((host) => host.id).toSet();
    final touched = {
      ...forwards.keys,
      for (final id in previous.records.keys)
        if (id.startsWith('forward:'))
          (previous.records[id]!['data'] as Map)['hostId'] as String,
    };
    for (final hostId in touched) {
      final incoming = {...?forwards[hostId]};
      final ordered = <PortForwardRule>[];
      if (hostIds.contains(hostId)) {
        for (final rule in await repository.loadPortForwards(hostId)) {
          final match = incoming.remove(rule.id);
          if (match != null) ordered.add(match);
        }
        ordered.addAll(incoming.values);
      }
      await repository.savePortForwards(hostId, ordered);
    }
    for (final id in previous.records.keys.where(
      (id) => !next.records.containsKey(id),
    )) {
      if (id.startsWith('host:')) {
        await repository.saveCredentials(id.substring(5), null);
      } else if (id.startsWith('key:')) {
        await repository.saveUserCredentials(id.substring(4), null);
      }
    }
  }
}
