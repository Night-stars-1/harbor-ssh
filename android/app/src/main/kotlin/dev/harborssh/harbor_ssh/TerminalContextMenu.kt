package dev.harborssh.harbor_ssh

import android.graphics.Rect
import android.os.Build
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Owns the system floating action mode and its outstanding Dart request. */
internal class TerminalContextMenu(
    messenger: BinaryMessenger,
    private val flutterView: () -> FlutterView?,
) {
    private val channel = MethodChannel(messenger, "dev.harborssh/terminal_context_menu")
    private var active: Request? = null

    private class Request(
        val id: Long,
        val result: MethodChannel.Result,
        val x: Int,
        val y: Int,
        val canCopy: Boolean,
        val canPaste: Boolean,
        val canSelectAll: Boolean,
    ) {
        var mode: ActionMode? = null
        var completed = false
    }

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> show(call, result)
            "hide" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id == null) {
                    result.error("invalid_arguments", "Missing menu id", null)
                } else {
                    if (active?.id == id) hide()
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun show(call: MethodCall, result: MethodChannel.Result) {
        // Finish the previous request even if this request cannot show a menu.
        hide()
        val id = call.argument<Number>("id")?.toLong()
        val x = call.argument<Number>("x")?.toDouble()
        val y = call.argument<Number>("y")?.toDouble()
        val pixelRatio = call.argument<Number>("pixelRatio")?.toDouble()
        val canCopy = call.argument<Boolean>("canCopy")
        val canPaste = call.argument<Boolean>("canPaste")
        val canSelectAll = call.argument<Boolean>("canSelectAll")
        if (id == null || x == null || y == null || pixelRatio == null ||
            !x.isFinite() || !y.isFinite() || !pixelRatio.isFinite() || pixelRatio <= 0 ||
            canCopy == null || canPaste == null || canSelectAll == null
        ) {
            result.error("invalid_arguments", "Invalid terminal menu arguments", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            !(canCopy || canPaste || canSelectAll)
        ) {
            result.success(null)
            return
        }
        val view = flutterView()
        if (view == null || !view.isAttachedToWindow || view.width <= 0 || view.height <= 0) {
            result.success(null)
            return
        }
        val request = Request(
            id, result,
            (x * pixelRatio).coerceIn(0.0, (view.width - 1).toDouble()).toInt(),
            (y * pixelRatio).coerceIn(0.0, (view.height - 1).toDouble()).toInt(),
            canCopy, canPaste, canSelectAll,
        )
        active = request
        val callback = object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                if (request.canCopy) menu.add(0, android.R.id.copy, 0, android.R.string.copy)
                if (request.canPaste) menu.add(0, android.R.id.paste, 1, android.R.string.paste)
                if (request.canSelectAll) menu.add(0, android.R.id.selectAll, 2, android.R.string.selectAll)
                return true
            }

            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean = false

            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
                val action = when (item.itemId) {
                    android.R.id.copy -> if (request.canCopy) "copy" else null
                    android.R.id.paste -> if (request.canPaste) "paste" else null
                    android.R.id.selectAll -> if (request.canSelectAll) "selectAll" else null
                    else -> null
                } ?: return false
                complete(request, action)
                finish(mode)
                return true
            }

            override fun onDestroyActionMode(mode: ActionMode) {
                complete(request, null)
            }

            override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
                val x = request.x.coerceIn(0, (view.width - 1).coerceAtLeast(0))
                val y = request.y.coerceIn(0, (view.height - 1).coerceAtLeast(0))
                outRect.set(x, y, x + 1, y + 1)
            }
        }
        val mode = try {
            view.startActionMode(callback, ActionMode.TYPE_FLOATING)
        } catch (_: RuntimeException) {
            null
        }
        if (mode == null) {
            complete(request, null)
        } else if (request.completed) {
            // A callback can complete synchronously during startActionMode.
            finish(mode)
        } else {
            request.mode = mode
        }
    }

    private fun complete(request: Request, action: String?) {
        if (request.completed) return
        request.completed = true
        if (active === request) active = null
        request.result.success(action)
    }

    private fun finish(mode: ActionMode) {
        try {
            mode.finish()
        } catch (_: RuntimeException) {
            // The owning view may already have detached during lifecycle teardown.
        }
    }

    fun hide() {
        val request = active ?: return
        complete(request, null)
        request.mode?.let(::finish)
    }

    fun dispose() {
        hide()
        channel.setMethodCallHandler(null)
    }
}
