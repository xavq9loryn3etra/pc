package com.popcorn.flutter_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.telephony.TelephonyManager
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // By default Android keeps the window clear of a camera notch /
        // punch hole in landscape, leaving a black strip down that side —
        // so fullscreen video stopped short of it. Let the app draw into the
        // cutout instead; Flutter reports the cutout as MediaQuery padding,
        // which SafeArea/padding-aware UI already keeps controls out of.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Where the phone actually is, for the streaming-service catalogue
        // (see TMDBService._countryCandidates): the language setting's
        // country is often just "US" for English. No permission needed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "popcorn/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "networkCountry") {
                    val tm = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                    val country = tm?.simCountryIso?.takeIf { it.isNotBlank() }
                        ?: tm?.networkCountryIso?.takeIf { it.isNotBlank() }
                    result.success(country?.uppercase())
                } else if (call.method == "freeBytes") {
                    // Space left on the disk holding a path: the torrents
                    // folder (see FreeSpace).
                    try {
                        result.success(StatFs(call.argument<String>("path")).availableBytes)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                } else if (call.method == "canInstallPackages") {
                    // Installing an update (see UpdateInstaller): Android 8+
                    // wants the user to allow it once.
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                } else if (call.method == "openInstallPermission") {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("unavailable", e.message, null)
                    }
                } else if (call.method == "installApk") {
                    // Android's own installer, which asks to confirm.
                    try {
                        val file = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.updates", file
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Whether battery saver is on, now and whenever it changes: the app
        // drops its frosted-glass blur meanwhile (see VisualEffectsService).
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "popcorn/power_save")
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var receiver: BroadcastReceiver? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                    events.success(power.isPowerSaveMode)
                    receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            events.success(power.isPowerSaveMode)
                        }
                    }
                    registerReceiver(
                        receiver,
                        IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                    )
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { unregisterReceiver(it) }
                    receiver = null
                }
            })
    }
}
