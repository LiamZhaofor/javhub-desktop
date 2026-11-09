package codes.liamzhao.javhub_desktop

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        /** Media buttons (notification, small window) arrive as this broadcast, "cmd" saying which. */
        const val ACTION_MEDIA = "codes.liamzhao.javhub.MEDIA"

        /** The running activity, for the playback service's commands. */
        @Volatile var instance: MainActivity? = null
    }

    private var pipChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null

    // the small window (picture in picture): allowed while a movie plays, its shape, playing or not
    private var pipEnabled = false
    private var pipW = 16
    private var pipH = 9
    private var pipPlaying = true

    private val mediaReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            command(intent.getStringExtra("cmd") ?: return)
        }
    }

    /** A media command (play / pause / toggle / rewind / forward / seek:<ms>) for the player. */
    fun command(cmd: String) {
        runOnUiThread { mediaChannel?.invokeMethod("command", cmd) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        val filter = IntentFilter(ACTION_MEDIA)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(mediaReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(mediaReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(mediaReceiver)
        } catch (_: Exception) {}
        if (instance === this) instance = null
        PlaybackService.stop(this)
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // App updates: hands a downloaded APK to the system's install screen.
        MethodChannel(messenger, "javhub/update").setMethodCallHandler { call, result ->
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
        MethodChannel(messenger, "javhub/screen").setMethodCallHandler { call, result ->
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
        // The small window (小窗): the player says when it may go small and how it is shaped;
        // the app tells the player when it went small or came back.
        pipChannel = MethodChannel(messenger, "javhub/pip").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        pipEnabled = call.argument<Boolean>("enabled") ?: false
                        pipW = (call.argument<Int>("w") ?: 16).coerceAtLeast(1)
                        pipH = (call.argument<Int>("h") ?: 9).coerceAtLeast(1)
                        pipPlaying = call.argument<Boolean>("playing") ?: true
                        updatePip()
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }
        // The media session and notification (ColorOS 流体云, control centre, lock screen, headsets).
        mediaChannel = MethodChannel(messenger, "javhub/media").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        @Suppress("UNCHECKED_CAST")
                        PlaybackService.update(this@MainActivity, call.arguments as Map<String, Any?>)
                        result.success(null)
                    }
                    "stop" -> {
                        PlaybackService.stop(this@MainActivity)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // ---------------- the small window ----------------

    private fun action(icon: Int, title: String, cmd: String, req: Int): RemoteAction {
        val pi = PendingIntent.getBroadcast(
            this, req, Intent(ACTION_MEDIA).setPackage(packageName).putExtra("cmd", cmd),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return RemoteAction(Icon.createWithResource(this, icon), title, title, pi)
    }

    private fun pipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < 26) return null
        // Android takes 1:2.39 to 2.39:1
        val ratio = (pipW.toDouble() / pipH).coerceIn(1 / 2.39 + 0.01, 2.39 - 0.01)
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
            .setActions(listOf(
                action(android.R.drawable.ic_media_rew, "后退", "rewind", 1),
                if (pipPlaying) action(android.R.drawable.ic_media_pause, "暂停", "pause", 2)
                else action(android.R.drawable.ic_media_play, "播放", "play", 2),
                action(android.R.drawable.ic_media_ff, "前进", "forward", 3),
            ))
        if (Build.VERSION.SDK_INT >= 31) {
            // swiping home while a movie plays shrinks it into the small window, smoothly
            b.setAutoEnterEnabled(pipEnabled).setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    private fun updatePip() {
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                setPictureInPictureParams(pipParams()!!)
            } catch (_: Exception) {}
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < 26 || !pipEnabled) return false
        return try {
            enterPictureInPictureMode(pipParams()!!)
        } catch (_: Exception) {
            false
        }
    }

    // Android 8-11 have no auto-enter: going home while a movie plays enters it here
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled && Build.VERSION.SDK_INT in 26..30) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("changed", isInPictureInPictureMode)
    }

    // the small window closed with its ✕: the activity stops without coming back
    override fun onStop() {
        super.onStop()
        if (Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode.not()) pipChannel?.invokeMethod("stopped", null)
    }
}
