package coffee.bookoo.bookoo_brew

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val filePickerChannel = "coffee.bookoo.bookoo_brew/file_picker"
    private val filePickerRequestCode = 7341
    private val fileSaverRequestCode = 7342
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingFileSaverResult: MethodChannel.Result? = null
    private var pendingFileBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filePickerChannel)
            .setMethodCallHandler(::handleFilePickerCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coffee.bookoo.bookoo_brew/bluetooth_host")
            .setMethodCallHandler { call, result ->
                if (call.method == "sdkInt") result.success(android.os.Build.VERSION.SDK_INT)
                else result.notImplemented()
            }
    }

    private fun handleFilePickerCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> pickFiles(call, result)
            "saveFile" -> saveFile(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pickFiles(call: MethodCall, result: MethodChannel.Result) {
        if (pendingFilePickerResult != null) {
            result.error("picker_busy", "文件选择器已经打开", null)
            return
        }

        val acceptTypes = call.argument<List<String>>("acceptTypes").orEmpty()
            .flatMap { it.split(',') }
            .mapNotNull(::mimeTypeFor)
            .distinct()
        val allowMultiple = call.argument<Boolean>("allowMultiple") == true
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (acceptTypes.size == 1) acceptTypes.first() else "*/*"
            if (acceptTypes.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, acceptTypes.toTypedArray())
            }
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }

        pendingFilePickerResult = result
        try {
            startActivityForResult(intent, filePickerRequestCode)
        } catch (error: ActivityNotFoundException) {
            pendingFilePickerResult = null
            result.error("picker_unavailable", "系统没有可用的文件选择器", error.message)
        }
    }

    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingFileSaverResult != null) {
            result.error("saver_busy", "文件保存器已经打开", null)
            return
        }

        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("invalid_file", "导出文件内容为空", null)
            return
        }
        val requestedName = call.argument<String>("fileName").orEmpty().trim()
        val fileName = requestedName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .ifEmpty { "brew-guide-data.json" }
        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.contains('/') }
            ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
            addFlags(
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }

        pendingFileSaverResult = result
        pendingFileBytes = bytes
        try {
            startActivityForResult(intent, fileSaverRequestCode)
        } catch (error: ActivityNotFoundException) {
            pendingFileSaverResult = null
            pendingFileBytes = null
            result.error("saver_unavailable", "系统没有可用的文件保存器", error.message)
        }
    }

    private fun mimeTypeFor(rawType: String): String? {
        val type = rawType.trim().lowercase()
        if (type.isEmpty() || type == "*/*") return null
        if (type.startsWith(".") && type.length > 1) {
            return MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(type.substring(1))
                ?: if (type == ".json") "application/json" else null
        }
        return type.takeIf { it.contains('/') }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            filePickerRequestCode -> handlePickedFiles(resultCode, data)
            fileSaverRequestCode -> handleSavedFile(resultCode, data)
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun handlePickedFiles(resultCode: Int, data: Intent?) {
        val result = pendingFilePickerResult
        pendingFilePickerResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.success(emptyList<String>())
            return
        }

        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                uris += clipData.getItemAt(index).uri
            }
        } else {
            data.data?.let(uris::add)
        }
        val takeFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        uris.forEach { uri ->
            try {
                contentResolver.takePersistableUriPermission(uri, takeFlags)
            } catch (_: SecurityException) {
                // 部分文档提供方仅授予本次读取权限，WebView 仍可立即导入。
            }
        }
        result?.success(uris.map(Uri::toString))
    }

    private fun handleSavedFile(resultCode: Int, data: Intent?) {
        val result = pendingFileSaverResult
        val bytes = pendingFileBytes
        pendingFileSaverResult = null
        pendingFileBytes = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) {
            result?.success(null)
            return
        }

        try {
            contentResolver.openOutputStream(uri, "w")?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IllegalStateException("无法打开保存位置")
            result?.success(uri.toString())
        } catch (error: Exception) {
            result?.error("save_failed", "写入导出文件失败", error.message)
        }
    }
}
