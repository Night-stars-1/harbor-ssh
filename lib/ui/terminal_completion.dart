import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/ssh_connection.dart';
import '../data/remote_commands.dart';
import '../domain/path_completion.dart';
import '../domain/shell_input.dart';
import '../domain/command_specs.dart';
import 'theme.dart';

class TerminalCandidate {
  const TerminalCandidate(
    this.label,
    this.suffix, {
    this.isDirectory = false,
    this.isHistory = false,
    this.isCommand = false,
    this.description = '',
    this.usage = '',
    this.kind = '',
  });
  final String label;
  final String suffix;
  final bool isDirectory;
  final bool isHistory;
  final bool isCommand;
  final String description;
  final String usage;
  final String kind;
  String get typeLabel => kind.isNotEmpty
      ? kind
      : isHistory
      ? '历史'
      : '命令';
}

class TerminalCompletion extends ChangeNotifier {
  TerminalCompletion(this.session) {
    session.terminal.addListener(refresh);
    session.addListener(refresh);
    session.inputGeneration.addListener(_inputPending);
    refresh();
  }

  final SshConnection session;
  Timer? _timer;
  int _revision = 0;
  bool _disposed = false;
  String? _dismissedLine;
  String? _cachedDirectory;
  DateTime? _cachedAt;
  List<RemotePathEntry> _cachedEntries = const [];
  PathCompletionRequest? request;
  String? _line;
  List<TerminalCandidate> entries = const [];
  int selected = 0;
  bool _selectionMoved = false;
  int keyboardSelectionRevision = 0;
  bool selectionFromKeyboard = false;

  bool get hasDescriptions =>
      entries.any((entry) => entry.description.isNotEmpty);
  double popupHeight(double width) {
    final listHeight = entries.length.clamp(0, 5) * 48.0 + 28;
    if (!hasDescriptions) return listHeight;
    return width >= 520
        ? listHeight.clamp(180.0, double.infinity)
        : listHeight + 112;
  }

  void select(int index) {
    if (index < 0 || index >= entries.length || index == selected) return;
    _selectionMoved = true;
    selectionFromKeyboard = false;
    selected = index;
    notifyListeners();
  }

  void _inputPending() {
    // Until remote echo arrives, the visible command may be one or more
    // keystrokes behind. Never append a candidate from that stale command.
    _revision++;
    _timer?.cancel();
    _clear();
  }

  void refresh() {
    _revision++;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 160), () => _load(_revision));
  }

  Future<void> _load(int revision) async {
    final input = session.status == ConnectionStatus.connected
        ? readShellInput(session.terminal)
        : null;
    if (input == null || input.command.trim().isEmpty) {
      _dismissedLine = null;
      _clear();
      return;
    }
    if (input.line == _dismissedLine) {
      _clear();
      return;
    }
    _dismissedLine = null;
    if (input.line != _line) _clear();
    final next = readPathCompletion(session.terminal);
    if (next == null) {
      await _loadCommands(input, revision);
      return;
    }
    final useCache =
        _cachedDirectory == next.directory &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(seconds: 2);
    List<RemotePathEntry> paths;
    try {
      paths = useCache
          ? _cachedEntries
          : await session
                .listDirectory(next.directory)
                .timeout(const Duration(seconds: 6));
    } catch (_) {
      paths = const [];
    }
    if (_disposed || revision != _revision) return;
    if (!useCache) {
      _cachedDirectory = next.directory;
      _cachedAt = DateTime.now();
      _cachedEntries = paths;
    }
    request = next;
    _line = input.line;
    final matches =
        paths
            .where(
              (entry) =>
                  (!next.directoriesOnly || entry.isDirectory) &&
                  entry.name.startsWith(next.prefix) &&
                  (next.prefix.startsWith('.') ||
                      !entry.name.startsWith('.')) &&
                  next.suffix(entry).isNotEmpty,
            )
            .toList()
          ..sort((a, b) {
            if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.compareTo(b.name);
          });
    entries = matches
        .take(100)
        .map(
          (entry) => TerminalCandidate(
            '${entry.name}${entry.isDirectory ? '/' : ''}',
            next.suffix(entry),
            isDirectory: entry.isDirectory,
          ),
        )
        .toList();
    selected = 0;
    notifyListeners();
  }

  Future<void> _loadCommands(ShellInput input, int revision) async {
    List<String> commands = const [];
    void publish() {
      if (_disposed || revision != _revision) return;
      final previous = !_selectionMoved || entries.isEmpty
          ? null
          : entries[selected].label;
      final names =
          commands
              .where(
                (name) =>
                    isCommandNamePrefix(name) &&
                    name.startsWith(input.command) &&
                    name != input.command,
              )
              .toSet()
              .toList()
            ..sort();
      final contextual = completeCommandContext(input.command);
      final candidates = contextual
          .map(
            (item) => TerminalCandidate(
              item.spec.name,
              item.suffix,
              isCommand: true,
              description: item.spec.description,
              usage: item.usage,
              kind: item.spec.name.startsWith('-') ? '选项' : '子命令',
            ),
          )
          .toList();
      candidates.addAll(
        names
            .take(50)
            .map(
              (name) => TerminalCandidate(
                name,
                name.substring(input.command.length),
                isCommand: true,
              ),
            )
            .toList(),
      );
      final seen = {...contextual.map((item) => item.completed), ...names};
      for (final command in session.commandHistory.matching(input.command)) {
        if (seen.add(command)) {
          candidates.add(
            TerminalCandidate(
              command,
              command.substring(input.command.length),
              isHistory: true,
            ),
          );
        }
        if (candidates.length >= 100) break;
      }
      _line = input.line;
      entries = candidates;
      final previousIndex = entries.indexWhere(
        (entry) => entry.label == previous,
      );
      selected = previousIndex < 0 ? 0 : previousIndex;
      notifyListeners();
    }

    // Show session history immediately; each remote source can arrive on its
    // own without holding up the other or replacing newer user input.
    publish();
    await Future.wait<void>([
      () async {
        try {
          await session.loadCommandHistory();
        } catch (_) {}
        publish();
      }(),
      if (isCommandNamePrefix(input.command))
        () async {
          try {
            commands = await session.listAvailableCommands();
          } catch (_) {}
          publish();
        }(),
    ]);
  }

  void _clear() {
    if (entries.isEmpty && _line == null) return;
    entries = const [];
    request = null;
    _line = null;
    selected = 0;
    _selectionMoved = false;
    selectionFromKeyboard = false;
    notifyListeners();
  }

  void dismiss() {
    _dismissedLine = readShellInput(session.terminal)?.line;
    _revision++;
    _timer?.cancel();
    _clear();
  }

  bool accept([int? index]) {
    final current = readShellInput(session.terminal);
    if (session.status != ConnectionStatus.connected ||
        entries.isEmpty ||
        current == null ||
        current.line != _line) {
      dismiss();
      return false;
    }
    final suffix = entries[index ?? selected].suffix;
    dismiss();
    // Path suffixes are escaped; history suffixes retain the original command.
    // A completion never sends Enter or replaces text the user has typed.
    session.terminal.textInput(suffix);
    return true;
  }

  KeyEventResult handleKey(KeyEvent event) {
    if (event is KeyUpEvent || entries.isEmpty) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      dismiss();
      return KeyEventResult.ignored;
    }
    if (readShellInput(session.terminal)?.line != _line) {
      dismiss();
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      dismiss();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && !keys.isShiftPressed) {
      return accept() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _selectionMoved = true;
      selectionFromKeyboard = true;
      keyboardSelectionRevision++;
      selected =
          (selected +
              (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
          entries.length;
      notifyListeners();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      dismiss();
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _timer?.cancel();
    session.terminal.removeListener(refresh);
    session.removeListener(refresh);
    session.inputGeneration.removeListener(_inputPending);
    super.dispose();
  }
}

class TerminalCompletionList extends StatefulWidget {
  const TerminalCompletionList({
    super.key,
    required this.completion,
    required this.onAccept,
  });
  final TerminalCompletion completion;
  final ValueChanged<int> onAccept;

  @override
  State<TerminalCompletionList> createState() => _TerminalCompletionListState();
}

class _TerminalCompletionListState extends State<TerminalCompletionList> {
  final _scroll = ScrollController();
  int _lastKeyboardRevision = 0;

  @override
  void initState() {
    super.initState();
    _lastKeyboardRevision = widget.completion.keyboardSelectionRevision;
  }

  @override
  void didUpdateWidget(TerminalCompletionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final completion = widget.completion;
    final revision = completion.keyboardSelectionRevision;
    if (_lastKeyboardRevision == revision) return;
    _lastKeyboardRevision = revision;
    final selected = completion.selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scroll.hasClients ||
          widget.completion != completion ||
          !completion.selectionFromKeyboard ||
          completion.keyboardSelectionRevision != revision ||
          completion.selected != selected) {
        return;
      }
      final start = selected * 48.0;
      final end = start + 48;
      final viewport = _scroll.position.viewportDimension;
      // Reveal only the clipped portion. Pointer hover and normal scrolling
      // never request a jump, even when a new row moves under the cursor.
      final offset = _scroll.offset;
      final target = start < offset
          ? start
          : end > offset + viewport
          ? end - viewport
          : offset;
      if (target != offset) {
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _details(BuildContext context) {
    final entry = widget.completion.entries[widget.completion.selected];
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('completion-details'),
      color: colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(
        const BorderRadius.only(
          topLeft: HarborShapes.xl,
          topRight: HarborShapes.sm,
          bottomLeft: HarborShapes.sm,
          bottomRight: HarborShapes.xl,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    entry.label,
                    softWrap: true,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.tertiaryContainer,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Text(
                      entry.typeLabel,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onTertiaryContainer),
                    ),
                  ),
                ),
              ],
            ),
            if (entry.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                entry.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (entry.usage.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: const BorderRadius.all(HarborShapes.sm),
                ),
                child: Text(
                  entry.usage,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completion = widget.completion;
    return Material(
      color: colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.zero,
                itemExtent: 48,
                itemCount: completion.entries.length,
                itemBuilder: (context, index) {
                  final entry = completion.entries[index];
                  final described = entry.description.isNotEmpty;
                  final selected = completion.selected == index;
                  final foreground = colors.onSurface;
                  return MouseRegion(
                    onHover: (_) => completion.select(index),
                    child: Semantics(
                      selected: completion.selected == index,
                      button: true,
                      child: InkWell(
                        borderRadius: const BorderRadius.all(HarborShapes.sm),
                        canRequestFocus: false,
                        onTap: () => widget.onAccept(index),
                        child: Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? Color.alphaBlend(
                                    colors.primary.withValues(alpha: 0.12),
                                    colors.surfaceContainerHigh,
                                  )
                                : Colors.transparent,
                            borderRadius: const BorderRadius.all(
                              HarborShapes.sm,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Icon(
                                entry.isHistory
                                    ? Icons.history_rounded
                                    : entry.kind == '选项'
                                    ? Icons.tune_rounded
                                    : entry.isCommand
                                    ? Icons.terminal_rounded
                                    : entry.isDirectory
                                    ? Icons.folder_outlined
                                    : Icons.insert_drive_file_outlined,
                                size: 18,
                                color: selected
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: described ? 4 : 1,
                                child: Text(
                                  entry.label,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: foreground,
                                        fontWeight: FontWeight.w500,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (described) ...[
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 5,
                                  child: Text(
                                    entry.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ] else if (entry.isCommand) ...[
                                const SizedBox(width: 8),
                                Text(
                                  entry.typeLabel,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (constraints.maxHeight >= 76)
              SizedBox(
                height: 28,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Tab 补全 · Esc 收起',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      Text(
                        '${completion.selected + 1}/${completion.entries.length}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completion = widget.completion;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = completion
            .popupHeight(constraints.maxWidth)
            .clamp(0.0, constraints.maxHeight);
        final showDetails = completion.hasDescriptions && height >= 180;
        return SizedBox(
          height: height,
          child: !showDetails
              ? _list(context)
              : constraints.maxWidth >= 520
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: SizedBox(height: height, child: _list(context)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 240,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: height),
                        child: _details(context),
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Expanded(child: _list(context)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 104,
                      width: double.infinity,
                      child: _details(context),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
