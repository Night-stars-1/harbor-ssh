// Runs against the real platform plugins, using only disposable test keys.
// flutter run -d windows --release -t tool/native_storage_smoke.dart
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:harbor_ssh/data/host_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final key = 'harbor.smoke.${DateTime.now().microsecondsSinceEpoch}';
  final preferences = PreferencesStore();
  final secrets = SecretStore();
  var succeeded = false;
  try {
    await preferences.write(key, 'configuration-probe');
    await secrets.write(key, 'credential-probe');
    if (await preferences.read(key) != 'configuration-probe' ||
        await secrets.read(key) != 'credential-probe') {
      throw StateError('Native storage round trip failed');
    }
    await preferences.delete(key);
    await secrets.delete(key);
    if (await preferences.read(key) != null ||
        await secrets.read(key) != null) {
      throw StateError('Native storage cleanup failed');
    }
    succeeded = true;
    // ignore: avoid_print
    print('HARBOR_NATIVE_STORAGE_OK');
  } catch (error) {
    // ignore: avoid_print
    print('HARBOR_NATIVE_STORAGE_FAILED: $error');
  } finally {
    await preferences.delete(key);
    await secrets.delete(key);
    exit(succeeded ? 0 : 1);
  }
}
