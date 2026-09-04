package com.jarviscopilot.mobile

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * Gapless playback of the realtime reply PCM (s16le mono) — plan 1.7.
 * One streaming AudioTrack per voice reply; chunks are written back-to-back
 * so there are no player stop/start seams. Mirrors iOS PcmStreamBridge.
 *
 * MethodChannel `jarviscopilot/pcm_stream`: ping, start{sampleRate},
 * feed{bytes}, flush, stop.
 */
object PcmStreamChannel {
    private var track: AudioTrack? = null
    private val writer = Executors.newSingleThreadExecutor()

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/pcm_stream")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> result.success(true)
                    "start" -> {
                        val sr = call.argument<Int>("sampleRate") ?: 24000
                        result.success(start(sr))
                    }
                    "feed" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(false)
                        } else {
                            val t = track
                            if (t == null) result.success(false) else {
                                writer.execute {
                                    try { t.write(bytes, 0, bytes.size) } catch (_: Throwable) {}
                                }
                                result.success(true)
                            }
                        }
                    }
                    "flush" -> { flush(); result.success(null) }
                    "stop" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun start(sampleRate: Int): Boolean {
        stop()
        return try {
            val min = AudioTrack.getMinBufferSize(
                sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            // ~1 s of headroom so a jittery tunnel doesn't underrun.
            val size = max(min * 4, sampleRate * 2)
            val t = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(size)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            t.play()
            track = t
            true
        } catch (_: Throwable) {
            track = null
            false
        }
    }

    @Synchronized
    private fun flush() {
        val t = track ?: return
        try {
            t.pause()
            t.flush()
            t.play()
        } catch (_: Throwable) {}
    }

    @Synchronized
    private fun stop() {
        val t = track ?: return
        track = null
        try { t.stop() } catch (_: Throwable) {}
        try { t.release() } catch (_: Throwable) {}
    }
}
