package codes.liamzhao.javhub_desktop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/**
 * A movie playing: a media session (what ColorOS shows in 流体云, the control centre and on the
 * lock screen, and what headset buttons talk to) and its notification, from a foreground
 * service, so the movie keeps playing in the small window or with the screen elsewhere.
 * The player (Dart) sends the state with [update]; the buttons come back to it through
 * [MainActivity.command].
 */
class PlaybackService : Service() {
    companion object {
        private const val CHANNEL = "playback"
        private const val ID = 7

        private var session: MediaSession? = null
        private var title = ""
        private var subtitle = ""
        private var art: Bitmap? = null
        private var artKey = 0
        private var playing = false
        private var running = false

        private fun session(ctx: Context): MediaSession = session ?: MediaSession(ctx.applicationContext, "JavHub").also {
            it.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = send("play")
                override fun onPause() = send("pause")
                override fun onSeekTo(pos: Long) = send("seek:$pos")
                override fun onRewind() = send("rewind")
                override fun onFastForward() = send("forward")
                override fun onSkipToPrevious() = send("rewind")
                override fun onSkipToNext() = send("forward")
                override fun onStop() = send("pause")
            })
            session = it
        }

        private fun send(cmd: String) {
            MainActivity.instance?.command(cmd)
        }

        /** title, subtitle, playing, position / duration (ms), speed, art (JPEG bytes, sent once) */
        fun update(ctx: Context, a: Map<String, Any?>) {
            val s = session(ctx)
            title = a["title"] as? String ?: title
            subtitle = a["subtitle"] as? String ?: subtitle
            (a["art"] as? ByteArray)?.let { bytes ->
                if (bytes.contentHashCode() != artKey) {
                    artKey = bytes.contentHashCode()
                    art = try { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) } catch (_: Exception) { null }
                }
            }
            playing = a["playing"] as? Boolean ?: playing
            val position = (a["position"] as? Number)?.toLong() ?: 0L
            val duration = (a["duration"] as? Number)?.toLong() ?: 0L
            val speed = (a["speed"] as? Number)?.toFloat() ?: 1f
            s.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration)
                .apply { art?.let { putBitmap(MediaMetadata.METADATA_KEY_ART, it) } }
                .build())
            s.setPlaybackState(PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_REWIND or PlaybackState.ACTION_FAST_FORWARD or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_STOP)
                .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, position, if (playing) speed else 0f)
                .build())
            s.isActive = true
            if (!running) {
                running = true
                val intent = Intent(ctx, PlaybackService::class.java)
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(intent) else ctx.startService(intent)
            } else {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(ID, build(ctx))
            }
        }

        fun stop(ctx: Context) {
            if (running) {
                running = false
                ctx.stopService(Intent(ctx, PlaybackService::class.java))
            }
            session?.let {
                it.isActive = false
                it.release()
            }
            session = null
            art = null
            artKey = 0
        }

        private fun button(ctx: Context, icon: Int, label: String, cmd: String, req: Int): Notification.Action {
            val pi = PendingIntent.getBroadcast(
                ctx, 100 + req, Intent(MainActivity.ACTION_MEDIA).setPackage(ctx.packageName).putExtra("cmd", cmd),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            return Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, icon), label, pi).build()
        }

        fun build(ctx: Context): Notification {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "正在播放", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "播放中的影片：流体云、控制中心和锁屏上的播放控制"
                    setShowBadge(false)
                })
            }
            val open = PendingIntent.getActivity(
                ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else Notification.Builder(ctx)
            return b.setSmallIcon(R.drawable.ic_stat_javhub)
                .setContentTitle(title)
                .setContentText(subtitle)
                .setLargeIcon(art)
                .setContentIntent(open)
                .setOngoing(playing)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(button(ctx, android.R.drawable.ic_media_rew, "后退", "rewind", 1))
                .addAction(
                    if (playing) button(ctx, android.R.drawable.ic_media_pause, "暂停", "pause", 2)
                    else button(ctx, android.R.drawable.ic_media_play, "播放", "play", 2),
                )
                .addAction(button(ctx, android.R.drawable.ic_media_ff, "前进", "forward", 3))
                .setStyle(Notification.MediaStyle().setMediaSession(session?.sessionToken).setShowActionsInCompactView(0, 1, 2))
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = build(this)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(ID, n)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }
}
