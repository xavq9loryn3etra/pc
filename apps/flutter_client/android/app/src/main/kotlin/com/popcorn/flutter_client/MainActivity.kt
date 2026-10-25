package com.popcorn.flutter_client

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.telephony.TelephonyManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                } else {
                    result.notImplemented()
                }
            }
    }
}
