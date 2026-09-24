import 'dart:io';

import 'package:flutter/services.dart';

/// Persists access granted by the macOS directory picker.
abstract final class LocalPathAccess {
  static const _channel = MethodChannel('harbor/local_paths');

  static Future<String?> pickDirectory({String? initialDirectory}) async {
    if (!Platform.isMacOS) return null;
    try {
      return await _channel.invokeMethod<String>('pickDirectory', {
        if (initialDirectory?.isNotEmpty == true)
          'initialDirectory': initialDirectory,
      });
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> restore(String path) async {
    if (!Platform.isMacOS || path.isEmpty) return null;
    try {
      return await _channel.invokeMethod<String>('restoreDirectory', {
        'path': path,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<void> commit(String path) async {
    if (!Platform.isMacOS || path.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('commitDirectory', {'path': path});
    } on MissingPluginException {
      // Tests and secondary engines may not own the native picker channel.
    }
  }

  static Future<void> clear() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('clearDirectory');
    } on MissingPluginException {
      // No bookmark exists when the platform channel is unavailable.
    }
  }
}
