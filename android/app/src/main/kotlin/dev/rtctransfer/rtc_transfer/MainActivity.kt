package dev.rtctransfer.rtc_transfer

import android.app.Activity
import android.content.Intent
import android.content.Context
import android.net.wifi.WifiManager
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.io.InputStream
import java.net.URLConnection
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.rtctransfer/storage"
        private const val PICK_DIRECTORY_REQUEST = 7351
    }

    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val storageExecutor = Executors.newSingleThreadExecutor()
    private val outputStreams = mutableMapOf<String, OutputStream>()
    private val inputStreams = mutableMapOf<String, InputStream>()
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    "pickDirectory" -> pickDirectory(result)
                    "openFile" -> runStorageOperation(result) {
                        openFile(
                            call.argument<String>("transferId")!!,
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                        null
                    }
                    "createDirectory" -> runStorageOperation(result) {
                        createDirectory(
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                        null
                    }
                    "writeFile" -> runStorageOperation(result) {
                        val transferId = call.argument<String>("transferId")!!
                        val bytes = call.argument<ByteArray>("bytes")!!
                        outputStreams[transferId]?.write(bytes)
                            ?: error("Receive file is not open")
                        null
                    }
                    "closeFile" -> runStorageOperation(result) {
                        closeFile(call.argument<String>("transferId")!!)
                        null
                    }
                    "abortFile" -> runStorageOperation(result) {
                        closeFile(call.argument<String>("transferId")!!)
                        null
                    }
                    "listDirectory" -> runStorageOperation(result) {
                        listDirectory(
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                    }
                    "listFilesRecursive" -> runStorageOperation(result) {
                        listFilesRecursive(
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                    }
                    "listDirectoriesRecursive" -> runStorageOperation(result) {
                        listDirectoriesRecursive(
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                    }
                    "pathSize" -> runStorageOperation(result) {
                        documentSize(
                            resolveDocument(
                                call.argument<String>("treeUri")!!,
                                call.argument<String>("relativePath")!!,
                            ),
                        )
                    }
                    "openReadFile" -> runStorageOperation(result) {
                        openReadFile(
                            call.argument<String>("handle")!!,
                            call.argument<String>("treeUri")!!,
                            call.argument<String>("relativePath")!!,
                        )
                    }
                    "readFile" -> runStorageOperation(result) {
                        readFile(
                            call.argument<String>("handle")!!,
                            call.argument<Int>("maxBytes")!!,
                        )
                    }
                    "closeReadFile" -> runStorageOperation(result) {
                        closeReadFile(call.argument<String>("handle")!!)
                        null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("rtc-transfer-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("already_active", "Directory picker is already active", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_DIRECTORY_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        try {
            val flags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            val label = DocumentFile.fromTreeUri(this, uri)?.name ?: uri.lastPathSegment
            result?.success(mapOf("uri" to uri.toString(), "label" to (label ?: uri.toString())))
        } catch (error: Exception) {
            result?.error("directory_permission", error.message, null)
        }
    }

    private fun openFile(transferId: String, treeUri: String, relativePath: String) {
        closeFile(transferId)
        var directory = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
            ?: error("Cannot open receive directory")
        val segments = relativePath
            .replace('\\', '/')
            .split('/')
            .filter { it.isNotBlank() && it != "." && it != ".." }
        require(segments.isNotEmpty()) { "Invalid receive file path" }
        for (segment in segments.dropLast(1)) {
            val existing = directory.findFile(segment)
            directory = when {
                existing?.isDirectory == true -> existing
                existing != null -> error("A file blocks receive directory: $segment")
                else -> directory.createDirectory(segment)
                    ?: error("Cannot create receive directory: $segment")
            }
        }
        val fileName = segments.last()
        directory.findFile(fileName)?.delete()
        val mimeType = URLConnection.guessContentTypeFromName(fileName)
            ?: "application/octet-stream"
        val file = directory.createFile(mimeType, fileName)
            ?: error("Cannot create receive file: $fileName")
        outputStreams[transferId] = contentResolver.openOutputStream(file.uri, "wt")
            ?: error("Cannot open receive file: $fileName")
    }

    private fun createDirectory(treeUri: String, relativePath: String) {
        var directory = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
            ?: error("Cannot open receive directory")
        for (segment in pathSegments(relativePath)) {
            val existing = directory.findFile(segment)
            directory = when {
                existing?.isDirectory == true -> existing
                existing != null -> error("A file blocks receive directory: $segment")
                else -> directory.createDirectory(segment)
                    ?: error("Cannot create receive directory: $segment")
            }
        }
    }

    private fun closeFile(transferId: String) {
        outputStreams.remove(transferId)?.let {
            it.flush()
            it.close()
        }
    }

    private fun resolveDocument(treeUri: String, relativePath: String): DocumentFile {
        var document = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
            ?: error("Cannot open shared directory")
        for (segment in pathSegments(relativePath)) {
            document = document.findFile(segment)
                ?: error("Shared path does not exist: $relativePath")
        }
        return document
    }

    private fun pathSegments(path: String): List<String> = path
        .replace('\\', '/')
        .split('/')
        .filter { it.isNotBlank() && it != "." && it != ".." }

    private fun joinRelative(parent: String, name: String): String =
        if (parent.isBlank()) name else "$parent/$name"

    private fun documentSize(document: DocumentFile): Long =
        if (document.isDirectory) {
            document.listFiles().sumOf { documentSize(it) }
        } else {
            document.length()
        }

    private fun listDirectory(treeUri: String, relativePath: String): List<Map<String, Any>> =
        resolveDocument(treeUri, relativePath).listFiles().mapNotNull { child ->
            val name = child.name ?: return@mapNotNull null
            mapOf(
                "name" to name,
                "path" to joinRelative(relativePath, name),
                "directory" to child.isDirectory,
                // Directory sizes are intentionally lazy. Recursively walking every
                // child here makes opening a folder such as .git extremely slow.
                "size" to if (child.isDirectory) 0L else child.length(),
                "modified" to child.lastModified(),
            )
        }

    private fun listFilesRecursive(treeUri: String, relativePath: String): List<String> {
        val target = resolveDocument(treeUri, relativePath)
        if (target.isFile) return listOf(relativePath)
        val files = mutableListOf<String>()
        fun collect(directory: DocumentFile, parent: String) {
            directory.listFiles().forEach { child ->
                val name = child.name ?: return@forEach
                val path = joinRelative(parent, name)
                if (child.isDirectory) collect(child, path) else if (child.isFile) files.add(path)
            }
        }
        collect(target, relativePath)
        return files
    }

    private fun listDirectoriesRecursive(treeUri: String, relativePath: String): List<String> {
        val target = resolveDocument(treeUri, relativePath)
        if (!target.isDirectory) return emptyList()
        val directories = mutableListOf(relativePath)
        fun collect(directory: DocumentFile, parent: String) {
            directory.listFiles().forEach { child ->
                val name = child.name ?: return@forEach
                if (child.isDirectory) {
                    val path = joinRelative(parent, name)
                    directories.add(path)
                    collect(child, path)
                }
            }
        }
        collect(target, relativePath)
        return directories
    }

    private fun openReadFile(
        handle: String,
        treeUri: String,
        relativePath: String,
    ): Long {
        closeReadFile(handle)
        val file = resolveDocument(treeUri, relativePath)
        require(file.isFile) { "Shared path is not a file: $relativePath" }
        inputStreams[handle] = contentResolver.openInputStream(file.uri)
            ?: error("Cannot open shared file: $relativePath")
        return file.length()
    }

    private fun readFile(handle: String, maxBytes: Int): ByteArray {
        val stream = inputStreams[handle] ?: error("Shared file is not open")
        val buffer = ByteArray(maxBytes)
        val count = stream.read(buffer)
        return if (count <= 0) ByteArray(0) else buffer.copyOf(count)
    }

    private fun closeReadFile(handle: String) {
        inputStreams.remove(handle)?.close()
    }

    private fun runStorageOperation(
        result: MethodChannel.Result,
        operation: () -> Any?,
    ) {
        storageExecutor.execute {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("storage_error", error.message, null) }
            }
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        outputStreams.values.forEach {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        outputStreams.clear()
        inputStreams.values.forEach {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        inputStreams.clear()
        storageExecutor.shutdown()
        super.onDestroy()
    }
}
