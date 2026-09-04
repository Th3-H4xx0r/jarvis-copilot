package com.jarviscopilot.mobile.skills

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * Streaming on-device speech recognition for Android (plan 4.2).
 *
 * Same contract as iOS's SpeechStreamBridge:
 *   start({id, sample_rate, prompt}) -> Boolean   false = unavailable here
 *   feed({id, pcm})                  -> null      PCM16 mono LE
 *   stop({id})                       -> String    final transcript ("" if none)
 *   cancel({id})                     -> null
 * with `{id, type: "partial"|"final"|"error", text}` on the
 * `jarviscopilot/speech_stream/partials` EventChannel.
 *
 * THE MIC PROBLEM. A plain [SpeechRecognizer] opens the microphone itself, and
 * the Dart side is already capturing from it for the WS stream. Two captures in
 * one app means one of them gets silence — which would break the working voice
 * path to speed up a fallback. So we never do that.
 *
 * Instead we use [RecognizerIntent.EXTRA_AUDIO_SOURCE] (API 31+): the
 * recognizer reads from a pipe we own, and `feed` writes the very same frames
 * Dart is streaming to the server. No second microphone, no conflict.
 *
 * We additionally require API 33's [SpeechRecognizer.createOnDeviceSpeechRecognizer]
 * so audio never leaves the device — the whole point of the local lane. On
 * anything older, or where no on-device recognizer is installed, `start`
 * returns false and Dart falls back to the server's STT exactly as before.
 */
object SpeechStreamChannel {

    private const val TAG = "JCSpeechStream"
    private const val METHOD_CHANNEL = "jarviscopilot/speech_stream"
    private const val EVENT_CHANNEL = "jarviscopilot/speech_stream/partials"

    private val main = Handler(Looper.getMainLooper())

    /** Pipe writes are blocking; keep them off the platform thread. */
    private val writer = Executors.newSingleThreadExecutor()

    private var events: EventChannel.EventSink? = null

    private var sessionId: String? = null
    private var recognizer: SpeechRecognizer? = null
    private var sink: OutputStream? = null
    private var latest: String = ""
    private var pending: MethodChannel.Result? = null

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                val id = call.argument<String>("id").orEmpty()
                when (call.method) {
                    "start" -> start(
                        ctx,
                        id,
                        call.argument<Int>("sample_rate") ?: 16_000,
                        result
                    )
                    "feed" -> {
                        call.argument<ByteArray>("pcm")?.let { feed(id, it) }
                        result.success(null)
                    }
                    "stop" -> stop(id, result)
                    "cancel" -> { cancel(id); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(args: Any?) {
                    events = null
                }
            })
    }

    // ── start ────────────────────────────────────────────────────────────────

    private fun start(ctx: Context, id: String, sampleRate: Int, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // No on-device recognizer API before 33 → server STT.
            result.success(false); return
        }
        main.post {
            try {
                // Re-checked inside the block so the API-33-only calls below are
                // guarded on the same code path (keeps Android lint happy too).
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    !SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)
                ) {
                    result.success(false); return@post
                }
                teardown()

                val pipe = ParcelFileDescriptor.createPipe()
                val read = pipe[0]
                sink = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])

                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                    )
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                    // Read our frames instead of opening the mic (see class doc).
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(
                        RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
                        AudioFormat.ENCODING_PCM_16BIT
                    )
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
                }

                val rec = SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
                rec.setRecognitionListener(listener(id))
                recognizer = rec
                sessionId = id
                latest = ""
                rec.startListening(intent)
                result.success(true)
            } catch (t: Throwable) {
                Log.w(TAG, "on-device streaming STT unavailable: ${t.javaClass.simpleName}")
                teardown()
                result.success(false)
            }
        }
    }

    private fun listener(id: String) = object : RecognitionListener {
        override fun onPartialResults(partial: Bundle?) {
            best(partial)?.let {
                latest = it
                emit(id, "partial", it)
            }
        }

        override fun onResults(results: Bundle?) {
            val text = best(results) ?: latest
            latest = text
            emit(id, "final", text)
            finish(text)
        }

        override fun onError(error: Int) {
            // Never log the text — only the code.
            Log.d(TAG, "recognition error $error")
            emit(id, "error", "")
            finish(latest)
        }

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        private fun best(bundle: Bundle?): String? =
            bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.takeIf { it.isNotBlank() }
    }

    // ── feed / stop / cancel ─────────────────────────────────────────────────

    private fun feed(id: String, pcm: ByteArray) {
        if (sessionId != id || pcm.isEmpty()) return
        val out = sink ?: return
        writer.execute {
            try {
                out.write(pcm)
            } catch (_: Throwable) {
                // Pipe closed (session ended) — nothing to do; the recognizer
                // has whatever it got.
            }
        }
    }

    private fun stop(id: String, result: MethodChannel.Result) {
        if (sessionId != id) { result.success(""); return }
        pending = result
        // EOF on the pipe is how the recognizer learns the utterance is over;
        // it then delivers onResults. Dart also applies its own timeout.
        writer.execute {
            try {
                sink?.close()
            } catch (_: Throwable) {
            }
            main.post { recognizer?.stopListening() }
        }
    }

    private fun cancel(id: String) {
        if (sessionId != id) return
        main.post {
            deliver("")
            teardown()
        }
    }

    /** Resolve a pending `stop` and release the recognizer. Main thread. */
    private fun finish(text: String) {
        main.post {
            deliver(text)
            teardown()
        }
    }

    private fun deliver(text: String) {
        val r = pending
        pending = null
        r?.success(text)
    }

    private fun teardown() {
        try { sink?.close() } catch (_: Throwable) {}
        sink = null
        try { recognizer?.destroy() } catch (_: Throwable) {}
        recognizer = null
        sessionId = null
        latest = ""
    }

    private fun emit(id: String, type: String, text: String) {
        main.post {
            events?.success(mapOf("id" to id, "type" to type, "text" to text))
        }
    }
}
