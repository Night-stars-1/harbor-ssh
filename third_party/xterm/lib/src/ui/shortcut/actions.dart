import 'dart:math' show max;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalActions extends StatelessWidget {
  const TerminalActions({
    super.key,
    required this.terminal,
    required this.controller,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text != null) {
              terminal.paste(text);
              controller.clearSelection();
            }
            return null;
          },
        ),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (intent) async {
            final selection = controller.selection;

            if (selection == null) {
              return;
            }

            final text = terminal.buffer.getText(selection);

            await Clipboard.setData(ClipboardData(text: text));

            return null;
          },
        ),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (intent) {
            final buffer = terminal.buffer;
            final lastLine = buffer.lines[buffer.height - 1];
            // A wrapped line never holds more than the viewport width, but an
            // unwrapped line can run past it; select the whole line either way.
            final endColumn = max(
              terminal.viewWidth,
              lastLine.getTrimmedLength(lastLine.length),
            );
            controller.setSelection(
              buffer.createAnchor(0, buffer.height - terminal.viewHeight),
              buffer.createAnchor(endColumn, buffer.height - 1),
              mode: SelectionMode.line,
            );
            return null;
          },
        ),
      },
      child: child,
    );
  }
}
