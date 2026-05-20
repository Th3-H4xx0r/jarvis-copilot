package com.jarviscopilot.mobile.skills

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.media.AudioManager
import android.os.Build
import android.provider.Settings
import android.telephony.SmsManager
import com.jarviscopilot.mobile.A11yService
import com.jarviscopilot.mobile.NotifListenerService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Wires up the Kotlin halves of the platform-specific Android skills.
/// Each channel name matches the one Dart-side in skills/android.dart.
object SkillChannels {
    fun registerAll(ctx: Context, engine: FlutterEngine) {
        TorchChannel.register(ctx, engine)
        SmsChannel.register(ctx, engine)
        NotifChannel.register(ctx, engine)
        A11yChannel.register(ctx, engine)
        TaskerChannel.register(ctx, engine)
        AppChannel.register(ctx, engine)
        AudioChannel.register(ctx, engine)
    }
}

// ── flashlight_on / flashlight_off ──────────────────────────────────────
//
// Cross-platform skill. We control the torch via CameraManager so it
// works regardless of which app is in front. Requires the device to
// have a back-facing camera with a flash unit; if not, we return a
// clean error and the agent can pick something else.

object TorchChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/torch")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "on" -> set(ctx, true, result)
                "off" -> set(ctx, false, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun set(ctx: Context, on: Boolean, result: MethodChannel.Result) {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val id = cm.cameraIdList.firstOrNull { camId ->
                val chars = cm.getCameraCharacteristics(camId)
                chars.get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            } ?: run {
                result.error("no_torch", "device has no torch", null); return
            }
            cm.setTorchMode(id, on)
            result.success(on)
        } catch (e: Throwable) {
            result.error("torch_failed", e.message, null)
        }
    }
}

// ── open_app ────────────────────────────────────────────────────────────

object AppChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/app")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val packageName = call.argument<String>("package_name")?.trim().orEmpty()
                    val appName = call.argument<String>("app")?.trim().orEmpty()
                    val schemeUrl = call.argument<String>("scheme_url")?.trim().orEmpty()
                    try {
                        val launched = open(ctx, packageName, appName, schemeUrl)
                        result.success(launched)
                    } catch (e: Throwable) {
                        result.error("activity_not_found", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun open(
        ctx: Context,
        packageName: String,
        appName: String,
        schemeUrl: String
    ): Map<String, Any?> {
        val pm = ctx.packageManager
        val requested = packageName.ifEmpty { appName }.ifEmpty { schemeUrl }

        if (packageName.isNotEmpty()) {
            launchPackage(ctx, packageName)?.let {
                return mapOf("launched" to true, "package" to packageName, "matched" to requested)
            }
        }

        val wantedNames = candidateNames(appName, schemeUrl)
        if (wantedNames.isNotEmpty()) {
            val main = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
            val matches = pm.queryIntentActivities(main, 0)
            val ranked = matches.mapNotNull { info ->
                val label = info.loadLabel(pm)?.toString().orEmpty()
                val labelNorm = normalizeName(label)
                val pkg = info.activityInfo.packageName
                val pkgNorm = normalizeName(pkg)
                val score = wantedNames.maxOf { scoreMatch(it, labelNorm, pkgNorm) }
                if (score > 0) Triple(score, label, info) else null
            }.maxByOrNull { it.first }
            if (ranked != null) {
                val match = ranked.third
                val label = ranked.second
                val pkg = match.activityInfo.packageName
                val intent = pm.getLaunchIntentForPackage(pkg)
                    ?: Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LAUNCHER)
                        .setClassName(pkg, match.activityInfo.name)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(intent)
                return mapOf(
                    "launched" to true,
                    "package" to pkg,
                    "label" to label,
                    "matched" to requested
                )
            }
        }

        if (schemeUrl.isNotEmpty()) {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(schemeUrl))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            return mapOf("launched" to true, "scheme_url" to schemeUrl, "matched" to requested)
        }

        throw ActivityNotFoundException("No app matched \"$requested\"")
    }

    private fun launchPackage(ctx: Context, packageName: String): Intent? {
        val intent = ctx.packageManager.getLaunchIntentForPackage(packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        return intent
    }

    private fun normalizeName(value: String): String =
        value.lowercase()
            .removeSuffix("://")
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()

    private fun candidateNames(appName: String, schemeUrl: String): List<String> {
        val raw = mutableListOf<String>()
        if (appName.isNotBlank()) raw.add(appName)
        val scheme = schemeName(schemeUrl)
        if (scheme.isNotBlank()) raw.add(scheme)
        return raw.flatMap { value ->
            val normalized = normalizeName(value)
            val compact = normalized.replace(" ", "")
            buildList {
                if (normalized.isNotBlank()) add(normalized)
                if (compact.isNotBlank() && compact != normalized) add(compact)
                if (compact.endsWith("app") && compact.length > 3) {
                    add(compact.removeSuffix("app"))
                }
            }
        }.distinct()
    }

    private fun scoreMatch(wanted: String, label: String, pkg: String): Int {
        if (wanted.isBlank()) return 0
        val compactLabel = label.replace(" ", "")
        val compactPkg = pkg.replace(" ", "")
        if (label == wanted) return 100
        if (compactLabel == wanted) return 98
        if (pkg == wanted || compactPkg == wanted) return 96
        if (label.isNotBlank() && (label.contains(wanted) || wanted.contains(label))) return 85
        if (compactLabel.isNotBlank() &&
            (compactLabel.contains(wanted) || wanted.contains(compactLabel))) return 82
        if (pkg.contains(wanted) || compactPkg.contains(wanted)) return 70
        val tokens = wanted.split(" ").filter { it.isNotBlank() }
        if (tokens.isNotEmpty() && tokens.all { label.contains(it) || pkg.contains(it) }) return 65
        return 0
    }

    private fun schemeName(value: String): String {
        if (value.isEmpty()) return ""
        val uri = Uri.parse(value)
        return uri.scheme.orEmpty()
    }
}

// ── adjust_volume / set_volume ─────────────────────────────────────────

object AudioChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/audio")
        ch.setMethodCallHandler { call, result ->
            val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            when (call.method) {
                "adjustVolume" -> {
                    val direction = call.argument<String>("direction")?.lowercase().orEmpty()
                    val steps = (call.argument<Number>("steps") ?: 1).toInt().coerceIn(1, 20)
                    when (direction) {
                        "up" -> repeat(steps) {
                            audio.adjustStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                AudioManager.ADJUST_RAISE,
                                AudioManager.FLAG_SHOW_UI
                            )
                        }
                        "down" -> repeat(steps) {
                            audio.adjustStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                AudioManager.ADJUST_LOWER,
                                AudioManager.FLAG_SHOW_UI
                            )
                        }
                        "mute" -> audio.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_MUTE,
                            AudioManager.FLAG_SHOW_UI
                        )
                        "unmute" -> audio.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_UNMUTE,
                            AudioManager.FLAG_SHOW_UI
                        )
                        else -> {
                            result.error("bad_args", "direction must be up/down/mute/unmute", null)
                            return@setMethodCallHandler
                        }
                    }
                    result.success(volumeState(audio))
                }
                "setVolume" -> {
                    val level = (call.argument<Number>("level") ?: 50).toInt().coerceIn(0, 100)
                    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                    val target = ((level / 100.0) * max).toInt().coerceIn(0, max)
                    audio.setStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        target,
                        AudioManager.FLAG_SHOW_UI
                    )
                    result.success(volumeState(audio))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun volumeState(audio: AudioManager): Map<String, Any> {
        val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return mapOf(
            "ok" to true,
            "stream" to "music",
            "current" to current,
            "max" to max,
            "level" to ((current * 100.0) / max).toInt()
        )
    }
}

// ── send_sms ────────────────────────────────────────────────────────────
//
// Uses SmsManager.sendTextMessage (no user tap required). The Play
// Store typically rejects apps holding SEND_SMS, but we're side-loading,
// so we accept the responsibility of guarding usage in the UI.

object SmsChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/sms")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "send" -> {
                    val number = call.argument<String>("number") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    if (number.isEmpty() || message.isEmpty()) {
                        result.error("bad_args", "number + message required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        // SmsManager.getDefault() is deprecated on API 31+;
                        // prefer getSystemService.
                        val mgr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            ctx.getSystemService(SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION") SmsManager.getDefault()
                        }
                        // Long messages get fragmented; sendMultipartTextMessage
                        // handles concatenation transparently.
                        val parts = mgr.divideMessage(message)
                        mgr.sendMultipartTextMessage(number, null, parts, null, null)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.error("send_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

// ── read_notifications ──────────────────────────────────────────────────
//
// Reads the cache the NotifListenerService keeps in memory.

object NotifChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/notif")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(NotifListenerService.snapshot())
                else -> result.notImplemented()
            }
        }
    }
}

// ── type_text / tap_at ──────────────────────────────────────────────────
//
// Routes through A11yService. The user must have enabled the service
// once in Settings → Accessibility; if it isn't running, we error.

object A11yChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/a11y")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isEnabled(ctx))
                "openSettings" -> {
                    ctx.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                }
                "typeText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val ok = A11yService.typeText(text)
                    if (!ok) {
                        result.error("a11y_unavailable",
                            "Enable JarvisCopilot in Settings → Accessibility", null)
                    } else result.success(true)
                }
                "tap" -> {
                    val x = (call.argument<Number>("x") ?: 0).toFloat()
                    val y = (call.argument<Number>("y") ?: 0).toFloat()
                    val ok = A11yService.tapAt(x, y)
                    if (!ok) {
                        result.error("a11y_unavailable", "AccessibilityService not active", null)
                    } else result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isEnabled(ctx: Context): Boolean {
        val expected = ComponentName(ctx, A11yService::class.java)
        val enabled = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(':').any {
            it.equals(expected.flattenToString(), ignoreCase = true) ||
                it.equals(expected.flattenToShortString(), ignoreCase = true)
        }
    }
}

// ── tasker_invoke ───────────────────────────────────────────────────────
//
// Tasker exposes a public Intent ACTION receiver that any app can fire.
// The user must have toggled "Allow External Access" in Tasker → Misc.

object TaskerChannel {
    fun register(ctx: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "jarviscopilot/tasker")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "run" -> {
                    val task = call.argument<String>("task") ?: ""
                    if (task.isEmpty()) {
                        result.error("bad_args", "task required", null); return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent("net.dinglisch.android.tasker.ACTION_TASK")
                            .setPackage("net.dinglisch.android.taskerm")
                            .putExtra("task_name", task)
                        ctx.sendBroadcast(intent)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.error("send_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
