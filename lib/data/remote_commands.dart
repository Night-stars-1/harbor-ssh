/// A fixed, read-only query on a separate SSH channel. User input is never
/// interpolated into shell code, and discovered executables are never run.
final remoteCommandCatalogQuery =
    "sh -c '${_catalogScript.replaceAll("'", "'\\''")}'";

const _catalogScript = r'''
printf '\n__HARBOR_COMMANDS_BEGIN__\n'
remaining=${PATH-}
while :; do
  directory=${remaining%%:*}
  [ -n "$directory" ] || directory=.
  for executable in "$directory"/*; do
    if [ -f "$executable" ] && [ -x "$executable" ]; then
      printf '%s\n' "${executable##*/}"
    fi
  done
  case "$remaining" in
    *:*) remaining=${remaining#*:} ;;
    *) break ;;
  esac
done
for builtin in alias bg break cd command continue echo eval exec exit export false fc fg getopts hash jobs kill printf pwd read readonly return set shift test times trap true type ulimit umask unalias unset wait; do
  command -v "$builtin" >/dev/null 2>&1 && printf '%s\n' "$builtin"
done
printf '__HARBOR_COMMANDS_END__\n'
''';

final _commandName = RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_.+\-]*$');

bool isCommandNamePrefix(String input) => _commandName.hasMatch(input);

List<String> parseRemoteCommands(String output) {
  final lines = output.split('\n').map((line) => line.trimRight()).toList();
  final start = lines.indexOf('__HARBOR_COMMANDS_BEGIN__');
  final end = lines.indexOf('__HARBOR_COMMANDS_END__', start + 1);
  if (start < 0 || end < 0) return const [];
  return lines
      .sublist(start + 1, end)
      .where((name) => name.length <= 256 && _commandName.hasMatch(name))
      .toSet()
      .toList()
    ..sort();
}
