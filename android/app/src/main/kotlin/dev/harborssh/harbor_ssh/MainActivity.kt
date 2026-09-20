package dev.harborssh.harbor_ssh

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.io.OutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val transfers = Executors.newSingleThreadExecutor()
    private var pendingCreate: MethodChannel.Result? = null
    private var output: OutputStream? = null
    @Volatile private var outputUri: Uri? = null
    private val createDocumentRequest = 4831

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.harborssh/file_transfer")
            .setMethodCallHandler { call, result ->
                if (call.method == "create") {
                    if (pendingCreate != null || outputUri != null) {
                        result.error("busy", "已有下载正在保存", null)
                    } else {
                        pendingCreate = result
                        try {
                            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                            }, createDocumentRequest)
                        } catch (error: Exception) {
                            pendingCreate = null
                            result.error("save_failed", error.message, null)
                        }
                    }
                } else if (call.method in listOf("write", "finish", "abort")) {
                    transfers.execute {
                        try {
                            when (call.method) {
                                "write" -> (output ?: error("没有打开的下载文件")).write(call.arguments as ByteArray)
                                "finish" -> {
                                    output?.flush()
                                    output?.close()
                                    output = null
                                    outputUri = null
                                }
                                "abort" -> cleanupDownload()
                            }
                            runOnUiThread { result.success(null) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("save_failed", error.message, null) }
                        }
                    }
                } else result.notImplemented()
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != createDocumentRequest) return
        val result = pendingCreate ?: return
        pendingCreate = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        outputUri = uri
        transfers.execute {
            try {
                output = contentResolver.openOutputStream(uri, "w") ?: error("无法打开保存位置")
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                try { cleanupDownload() } catch (_: Exception) {}
                runOnUiThread { result.error("save_failed", error.message, null) }
            }
        }
    }

    private fun cleanupDownload() {
        try { output?.close() } finally {
            output = null
            val uri = outputUri
            outputUri = null
            if (uri != null) DocumentsContract.deleteDocument(contentResolver, uri)
        }
    }

    override fun onDestroy() {
        pendingCreate?.error("closed", "文件选择已结束", null)
        pendingCreate = null
        transfers.execute { try { cleanupDownload() } catch (_: Exception) {} }
        transfers.shutdown()
        super.onDestroy()
    }
}
