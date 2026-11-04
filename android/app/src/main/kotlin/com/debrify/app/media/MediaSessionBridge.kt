package com.debrify.app.media

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The in-app player's media session: tells Android what is playing (title,
 * poster, position) so headset buttons, Bluetooth/car controls and media keys
 * can play, pause, seek and skip it, and posts a media notification with the
 * same controls. Fed from Dart over `debrify/media_session`; commands go back
 * over the same channel as `command`.
 *
 * Uses the framework [MediaSession] directly: the session lives with the
 * activity that plays, so no MediaBrowserService (and no second Flutter
 * engine, which audio_service would need) is involved.
 */
class MediaSessionBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var session: MediaSession? = null
    private var receiverRegistered = false

    private var title = ""
    private var subtitle: String? = null
    private var artwork: Bitmap? = null
    private var durationMs = 0L
    private var positionMs = 0L
    private var playing = false
    private var rate = 1f
    private var canNext = false
    private var canPrevious = false

    private val notificationManager =
        activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // ── Audio focus ──────────────────────────────────────────────────────
    //
    // mpv's Android audio output never asks for audio focus, so without this
    // the film played on top of whatever music app was running. The player
    // takes focus the moment it starts playing (music pauses), gives it up
    // when it closes (music may resume), and reacts to losing it like every
    // media app: a call or another player pauses it; a short interruption
    // resumes it afterwards. Trailers and reels never reach this bridge, so
    // a muted ambient video never takes focus.
    private val audioManager =
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var hasAudioFocus = false
    private var resumeOnFocusGain = false
    private var focusRequest: AudioFocusRequest? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocusGain = false
                hasAudioFocus = false
                if (playing) send("pause")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                resumeOnFocusGain = playing
                if (playing) send("pause")
            }
            // The system ducks us on O+; a film keeps playing quieter.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> Unit
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasAudioFocus = true
                if (resumeOnFocusGain) send("play")
                resumeOnFocusGain = false
            }
        }
    }

    private fun requestAudioFocus() {
        if (hasAudioFocus) return
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
                .also { focusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        hasAudioFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        resumeOnFocusGain = false
        if (!hasAudioFocus) return
        hasAudioFocus = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
    }

    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PLAY -> send("play")
                ACTION_PAUSE -> send("pause")
                ACTION_NEXT -> send("next")
                ACTION_PREVIOUS -> send("previous")
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    update(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                    result.success(null)
                }
                "clear" -> {
                    clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun send(action: String, extra: Map<String, Any>? = null) {
        activity.runOnUiThread {
            channel.invokeMethod("command", mapOf("action" to action) + (extra ?: emptyMap()))
        }
    }

    private fun ensureSession(): MediaSession {
        session?.let { return it }
        val created = MediaSession(activity, "DebrifyPlayer")
        created.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = send("play")
            override fun onPause() = send("pause")
            override fun onStop() = send("pause")
            override fun onSkipToNext() = send("next")
            override fun onSkipToPrevious() = send("previous")
            override fun onFastForward() = send("seekBy", mapOf("offsetMs" to 10_000))
            override fun onRewind() = send("seekBy", mapOf("offsetMs" to -10_000))
            override fun onSeekTo(pos: Long) = send("seek", mapOf("positionMs" to pos))
        })
        created.setSessionActivity(
            PendingIntent.getActivity(
                activity,
                0,
                Intent(activity, activity.javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        created.isActive = true
        session = created
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(ACTION_PLAY)
                addAction(ACTION_PAUSE)
                addAction(ACTION_NEXT)
                addAction(ACTION_PREVIOUS)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                activity.registerReceiver(actionReceiver, filter)
            }
            receiverRegistered = true
        }
        return created
    }

    private fun update(args: Map<*, *>) {
        val fresh = session == null
        val s = ensureSession()
        val newTitle = args["title"] as? String ?: title
        val newSubtitle = args["subtitle"] as? String
        val bytes = args["artwork"] as? ByteArray
        val clearArtwork = args["clearArtwork"] == true
        val newDuration = (args["durationMs"] as? Number)?.toLong() ?: durationMs
        val metadataChanged = fresh || newTitle != title ||
            newSubtitle != subtitle || bytes != null || clearArtwork ||
            newDuration != durationMs
        title = newTitle
        subtitle = newSubtitle
        if (bytes != null) artwork = decodeArtwork(bytes)
        if (clearArtwork) artwork = null
        durationMs = newDuration
        positionMs = (args["positionMs"] as? Number)?.toLong() ?: positionMs
        playing = args["playing"] as? Boolean ?: playing
        rate = (args["rate"] as? Number)?.toFloat() ?: rate
        canNext = args["canNext"] as? Boolean ?: canNext
        canPrevious = args["canPrevious"] as? Boolean ?: canPrevious
        if (args["playing"] == true) requestAudioFocus()

        if (metadataChanged) {
            val metadata = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
            subtitle?.let {
                metadata.putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, it)
                metadata.putString(MediaMetadata.METADATA_KEY_ARTIST, it)
            }
            artwork?.let {
                metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, it)
                metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it)
                metadata.putBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON, it)
            }
            s.setMetadata(metadata.build())
        }

        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or
            PlaybackState.ACTION_FAST_FORWARD or PlaybackState.ACTION_REWIND or
            PlaybackState.ACTION_STOP
        if (canNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        if (canPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    positionMs,
                    if (playing) rate else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .build(),
        )
        postNotification(s)
    }

    /** Posters arrive at full size; the session only needs a thumbnail. */
    private fun decodeArtwork(bytes: ByteArray): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 512 && bounds.outHeight / (sample * 2) >= 512) {
            sample *= 2
        }
        BitmapFactory.decodeByteArray(
            bytes,
            0,
            bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        )
    } catch (_: Throwable) {
        null
    }

    private fun actionIntent(action: String, code: Int): PendingIntent =
        PendingIntent.getBroadcast(
            activity,
            code,
            Intent(action).setPackage(activity.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun postNotification(s: MediaSession) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                notificationManager.getNotificationChannel(NOTIFICATION_CHANNEL) == null
            ) {
                notificationManager.createNotificationChannel(
                    NotificationChannel(
                        NOTIFICATION_CHANNEL,
                        "Now playing",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        setShowBadge(false)
                        setSound(null, null)
                    },
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(activity, NOTIFICATION_CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(activity)
            }
            val compact = mutableListOf<Int>()
            var index = 0
            if (canPrevious) {
                builder.addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_previous,
                        "Previous",
                        actionIntent(ACTION_PREVIOUS, 1),
                    ).build(),
                )
                compact.add(index++)
            }
            builder.addAction(
                if (playing) {
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_pause,
                        "Pause",
                        actionIntent(ACTION_PAUSE, 2),
                    ).build()
                } else {
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_play,
                        "Play",
                        actionIntent(ACTION_PLAY, 3),
                    ).build()
                },
            )
            compact.add(index++)
            if (canNext) {
                builder.addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_next,
                        "Next",
                        actionIntent(ACTION_NEXT, 4),
                    ).build(),
                )
                compact.add(index)
            }
            val notification = builder
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle(title)
                .setContentText(subtitle)
                .setLargeIcon(artwork)
                .setContentIntent(s.controller.sessionActivity)
                .setOngoing(playing)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setStyle(
                    Notification.MediaStyle()
                        .setMediaSession(s.sessionToken)
                        .setShowActionsInCompactView(*compact.toIntArray()),
                )
                .build()
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Notifications not allowed: the session alone still serves
            // headset buttons and media keys.
        } catch (_: Throwable) {
        }
    }

    fun clear() {
        abandonAudioFocus()
        try {
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Throwable) {
        }
        session?.let {
            it.isActive = false
            it.release()
        }
        session = null
        artwork = null
        title = ""
        subtitle = null
        durationMs = 0
        positionMs = 0
        playing = false
    }

    fun dispose() {
        clear()
        if (receiverRegistered) {
            try {
                activity.unregisterReceiver(actionReceiver)
            } catch (_: Throwable) {
            }
            receiverRegistered = false
        }
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "debrify/media_session"
        private const val NOTIFICATION_CHANNEL = "debrify_now_playing"
        private const val NOTIFICATION_ID = 0x4d5301
        private const val ACTION_PLAY = "com.debrify.app.media.PLAY"
        private const val ACTION_PAUSE = "com.debrify.app.media.PAUSE"
        private const val ACTION_NEXT = "com.debrify.app.media.NEXT"
        private const val ACTION_PREVIOUS = "com.debrify.app.media.PREVIOUS"
    }
}
