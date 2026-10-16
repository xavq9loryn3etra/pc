package com.popcorn.flutter_client

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

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
}
