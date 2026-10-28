import 'package:flutter/services.dart';

const systemFontsChannel = MethodChannel('harbor/system_fonts');

/// Fixed-pitch font families installed on this desktop.
abstract final class SystemFonts {
  /// Unique family names sorted case-insensitively. Empty when the platform
  /// cannot enumerate fonts (Android, tests); callers keep free-text entry.
  static Future<List<String>> monospaceFamilies() async {
    final List<String> families;
    try {
      families =
          await systemFontsChannel.invokeListMethod<String>(
            'monospaceFamilies',
          ) ??
          const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
    return {
      for (final family in families)
        if (family.trim().isNotEmpty) family.trim(),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
}
