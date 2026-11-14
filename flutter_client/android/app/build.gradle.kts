import java.io.FileInputStream
import java.util.Properties

// The release signing key: android/key.properties on a developer's PC
// (gitignored), or ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD /
// ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD on CI. Without either, release
// builds fall back to the debug key. Every published APK must use the same
// key, or it won't install over the one before it.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}
fun signingValue(property: String, env: String): String? =
    keystoreProperties.getProperty(property) ?: System.getenv(env)
val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.popcorn.flutter_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.popcorn.flutter_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// Release builds ship for modern 64-bit ARM phones only. Flutter, mpv and
// libtorrent each bring libraries for every ABI, which add ~70 MB nobody
// needs. (ndk.abiFilters doesn't work here: the Flutter plugin resets it.)
//
// The TV download (Popcorn-Android-TV.apk) also carries 32-bit ARM: many TV
// sticks (Chromecast with Google TV, most Fire TV Sticks) run 32-bit apps
// only. It's built with -PpopcornAbis=arm64-v8a,armeabi-v7a (and
// --target-platform android-arm,android-arm64); see publish-release.yml.
val releaseAbis = (project.findProperty("popcornAbis") as String? ?: "arm64-v8a")
    .split(",").map { it.trim() }.filter { it.isNotEmpty() }
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
                .filter { it !in releaseAbis }
                .map { "lib/$it/**" }
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider, for handing a downloaded update to Android's installer
    // (UpdateFileProvider).
    implementation("androidx.core:core:1.13.1")
}
