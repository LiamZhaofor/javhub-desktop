package codes.liamzhao.javhub_desktop

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App updates: hands a downloaded APK to the system's install screen.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "javhub/update").setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val file = File(call.argument<String>("path")!!)
                val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                result.success(true)
            } catch (e: Exception) {
                result.error("install", e.message, null)
            }
        }
    }
}
