# Harbor SSH compatibility patch

This is the runtime source of xterm 4.0.0 from pub.dev, under its original MIT license.

Local changes in `lib/src/ui/custom_text_edit.dart`:
- Supply `View.of(context).viewId` when attaching the native text input client.
  Current Flutter Windows engines reject configurations without a view ID.
- Reattach the focused input client after hot reload so the corrected configuration
  takes effect in an existing SSH session.

Regression coverage: `test/terminal_test.dart` in the application verifies the
view ID, ordinary text, IME composition/commit, Enter, and clipboard shortcuts.
Keep this patch until the upstream dependency supplies the current view ID.

- Expose `Buffer.insertionX` for shell completion at a pending line wrap. Unlike
  the visual cursor, this boundary includes the final typed cell.

## No-wrap mode (the appearance "terminal wrap" switch)

`Terminal.lineWrap` defaults to `true`. Switched off, output is never wrapped:
printable characters are appended to the current logical line, which can be far
wider than the viewport. While it is off the terminal applies
`max(viewport, Terminal.unwrapColumns)` (512) columns instead of the viewport
width, so the PTY keeps formatting for a screen that wide, and the view scrolls
horizontally. Switching the setting back on rewraps the buffer at the viewport
width.

`lib/src/terminal.dart`
- `lineWrap` flag (default `true`) with a change notification.
- `Terminal.unwrapColumns = 512`: the floor of the applied width while unwrapped.
- Switching wrapping on calls `Buffer.rewrap()`. The renderer only resizes when the
  applied width changes, so a viewport that is already at least as wide as the
  applied width would otherwise leave over-wide lines unwrapped.

`lib/src/core/buffer/buffer.dart`
- `insertionX`: unwrapped, the boundary follows the real cursor and can exceed the
  viewport; wrapped, it keeps including the pending-wrap cell.
- `_editableWidth`/`_cursorLimit`: unwrapped bounds are `max(viewWidth, line.length)`.
  `writeChar`, `backspace`, `eraseLineFromCursor`, `eraseLineToCursor`, `eraseLine`,
  `eraseDisplayFromCursor`, `eraseDisplayToCursor`, `eraseDisplay`, `deleteChars`
  and the cursor setters use them, so cells past the viewport stay reachable and the
  cursor may sit there.
- `resize`: while unwrapped, reflow runs only when the width grows and no line
  extends past the old width (`_lineExtendsPast`); otherwise only shorter lines are
  padded, and shrinking never splits a line.
- `_reflow`: reflows, pads to the viewport height, and carries the cursor through
  with a `CellAnchor` on its cell so row and column map to the same offset inside
  the logical line. Without it, switching wrapping back on left the cursor on the
  first row and the next keystroke overwrote the last character. The cursor row is
  resolved against the height being resized to, because `viewHeight` still returns
  the old height while `resize` runs.
- `rewrap`: reflows at the current width, used by the `lineWrap` setter.
- `getWordBoundary`: the unwrapped scan stops at the line length.

`lib/src/core/reflow.dart`
- `_LineReflow.add` trims with `getTrimmedLength(max(oldWidth, line.length))`.
  Scanning only `oldWidth` dropped every column past it, so switching wrapping back
  on truncated a 2000 character line to the old width.
- `_LineReflow.add` also splits a line that is wider than the target width when the
  target is not narrower than `oldWidth` (reflowing at an unchanged width), and
  skips its wide-char lookback when a reused line already filled the builder, where
  there is no copied cell to inspect.

`lib/src/ui/render.dart`
- `horizontalOffset`/`maxHorizontalExtent`, `_contentColumns`,
  `_measureContentColumns`, `_revealCursor`, `_followHorizontal`: horizontal
  scrolling of unwrapped content; `_logicalColumns` applies
  `max(viewport, Terminal.unwrapColumns)` as the applied width.
- `_paint` clips to the viewport and translates by `-horizontalOffset`;
  `getOffset`/`getCellOffset`/`cursorOffset` include the offset, hit testing clamps
  to `max(viewWidth, contentColumns)`, and `_paintSegment` falls back to the line
  length for unwrapped segments.

`lib/src/ui/terminal_view.dart`
- Horizontal `ScrollController`, the 12 px scrollbar row
  (`ValueKey('terminal-horizontal-scrollbar')`) shown only while content is hidden,
  horizontal wheel translation, and the metrics/offset sync with
  `RenderTerminal.horizontalOffset`.

`lib/src/ui/shortcut/actions.dart`
- Select-all ends at `max(viewWidth, last line content width)`, so the last line of
  an unwrapped buffer is copied in full. Intermediate lines were already taken whole
  and wrapped buffers keep the previous whole-row extent.

Application side: `AppearancePreferences.terminalWrap` (`lib/domain/appearance.dart`)
defaults to `true`, is written by `toJson` like the other flags, and `fromJson` only
disables wrapping for an explicit `false`. `TerminalPane`/`TerminalWorkspace` forward
it to `terminal.lineWrap`; the switch is in the appearance settings;
`test/terminal_wrap_test.dart` covers the wrap behaviour.

Limitations:
- Reflow keeps the cursor on its own cell but does not remap other state: a cursor
  that sits above a line which expands during the reflow is clamped back into the
  viewport and can be drawn on the wrong row (upstream behaviour).
- With `reflowEnabled = false`, or in the alternate buffer, a wrapped resize still
  truncates lines wider than the new width (upstream path).
