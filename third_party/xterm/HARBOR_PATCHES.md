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

- Expose `Buffer.insertionX` for shell completion at a pending line wrap. Unlike the visual cursor, this boundary includes the final typed cell.
