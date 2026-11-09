package codes.liamzhao.javhub_desktop

import android.content.Context
import android.content.Intent
import android.media.AudioManager
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
        // The player's swipes: this window's brightness (-1 = the system's again) and the media volume.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "javhub/screen").setMethodCallHandler { call, result ->
            val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            when (call.method) {
                "getBrightness" -> {
                    val b = window.attributes.screenBrightness
                    result.success(if (b >= 0f) b.toDouble() else try {
                        android.provider.Settings.System.getInt(contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS) / 255.0
                    } catch (e: Exception) { 0.5 })
                }
                "setBrightness" -> {
                    val v = (call.argument<Double>("value") ?: -1.0).toFloat()
                    window.attributes = window.attributes.apply { screenBrightness = if (v < 0f) -1f else v.coerceIn(0.01f, 1f) }
                    result.success(null)
                }
                "getVolume" -> result.success(audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
                "setVolume" -> {
                    val v = (call.argument<Double>("value") ?: 0.5).coerceIn(0.0, 1.0)
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(v * max).toInt(), 0)
                    result.success(audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
                }
                else -> result.notImplemented()
            }
        }
    }
}
