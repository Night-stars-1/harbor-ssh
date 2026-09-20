import 'dart:io';

/// Open a web URL with the desktop's default browser. Pass it as a process
/// argument, never as shell command text (URLs may contain shell metacharacters).
Future<void> openWebLink(Uri uri) async {
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw ArgumentError.value(uri, 'uri', 'Expected an HTTP(S) URL');
  }
  final executable = Platform.isWindows
      ? 'explorer.exe'
      : Platform.isMacOS
      ? '/usr/bin/open'
      : 'xdg-open';
  await Process.start(executable, [
    uri.toString(),
  ], mode: ProcessStartMode.detached);
}
