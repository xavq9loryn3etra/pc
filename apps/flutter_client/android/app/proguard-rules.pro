# Flutter's own default rules (method channels, plugin registrant, embedding)
# are supplied automatically by the Flutter Gradle plugin. The rules below
# cover this app's native/reflection-heavy dependencies that are more likely
# to need explicit keeps under R8 shrinking.

# media_kit / libmpv JNA bindings
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { public *; }

# libtorrent_flutter native bridge
-keep class com.libtorrent.** { *; }
-keep class libtorrent_flutter.** { *; }

# Firebase (Remote Config / Core) reflection-based config parsing
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# webview_flutter JS bridge objects
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# flutter_foreground_task service + notification classes
-keep class com.pravera.flutter_foreground_task.** { *; }

# Gson/JSON reflection used transitively by several plugins
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn okio.**
-dontwarn okhttp3.**
