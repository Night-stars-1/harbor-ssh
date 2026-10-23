import 'package:flutter/foundation.dart';

import 'host.dart';

/// One connection's replacement endpoint inside a [NetworkIdentity].
/// An empty [address] or a null [port] keeps the connection's own value.
@immutable
class EndpointOverride {
  const EndpointOverride({this.address = '', this.port});
  final String address;
  final int? port;
  bool get isEmpty => address.isEmpty && port == null;

  Map<String, Object> toJson() => {
    if (address.isNotEmpty) 'address': address,
    'port': ?port,
  };

  factory EndpointOverride.fromJson(Map<dynamic, dynamic> json) {
    final port = json['port'];
    return EndpointOverride(
      address: '${json['address'] ?? ''}'.trim(),
      port: port is int && port >= 1 && port <= 65535 ? port : null,
    );
  }
}

/// A network scenario (office LAN, frp tunnel, proxy…) that reroutes saved
/// connections to other addresses and ports. Host-key trust stays bound to the
/// connection's own endpoint, so the same server reached through a tunnel is
/// still verified against the fingerprint the user already confirmed.
@immutable
class NetworkIdentity {
  const NetworkIdentity({
    required this.id,
    required this.name,
    this.overrides = const {},
  });
  final String id, name;

  /// Keyed by [Host.id].
  final Map<String, EndpointOverride> overrides;

  /// The address and port to dial for [host] under this identity.
  (String, int) endpointOf(Host host) {
    final override = overrides[host.id];
    return (
      override == null || override.address.isEmpty
          ? host.address
          : override.address,
      override?.port ?? host.port,
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'overrides': {
      for (final entry in overrides.entries)
        if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
    },
  };

  factory NetworkIdentity.fromJson(Map<dynamic, dynamic> json) =>
      NetworkIdentity(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        overrides: {
          for (final entry in (json['overrides'] as Map? ?? const {}).entries)
            if (entry.value is Map)
              '${entry.key}': EndpointOverride.fromJson(entry.value as Map),
        }..removeWhere((_, value) => value.isEmpty),
      );
}

/// Every identity on this device and the one currently in effect. The
/// definitions sync like connections, but which network this device is on is
/// [activeId] and never leaves it.
@immutable
class NetworkIdentities {
  const NetworkIdentities({this.identities = const [], this.activeId = ''});
  final List<NetworkIdentity> identities;

  /// Empty: connections use their own address and port.
  final String activeId;

  NetworkIdentity? get active =>
      identities.where((identity) => identity.id == activeId).firstOrNull;

  (String, int) endpointOf(Host host) =>
      active?.endpointOf(host) ?? (host.address, host.port);

  NetworkIdentities copyWith({
    List<NetworkIdentity>? identities,
    String? activeId,
  }) {
    final next = identities ?? this.identities;
    final id = activeId ?? this.activeId;
    return NetworkIdentities(
      identities: next,
      activeId: next.any((identity) => identity.id == id) ? id : '',
    );
  }

  Map<String, Object> toJson() => {
    'identities': [for (final identity in identities) identity.toJson()],
    if (activeId.isNotEmpty) 'activeId': activeId,
  };

  factory NetworkIdentities.fromJson(Map<dynamic, dynamic> json) =>
      const NetworkIdentities().copyWith(
        identities: [
          for (final item in json['identities'] as List? ?? const [])
            if (item is Map) NetworkIdentity.fromJson(item),
        ],
        activeId: '${json['activeId'] ?? ''}',
      );
}
