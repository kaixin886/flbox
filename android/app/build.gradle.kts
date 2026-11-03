import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Fixed dev signing key: the keystore ships base64-encoded in the repo
// (flbox.jks.b64) and is materialized here on first use, so every CI
// build signs identically and new versions install over old ones.
val flboxJks = file("flbox.jks")
if (!flboxJks.exists()) {
    val flboxB64 = file("flbox.jks.b64")
    if (flboxB64.exists()) {
        flboxJks.writeBytes(
            Base64.getMimeDecoder().decode(flboxB64.readText())
        )
    }
}

android {
    namespace = "com.kaixin886.flbox"
    // file_picker 8.x is compiled against API 36 and requires consumers
    // to compile against it too; flutter.compileSdkVersion resolves to
    // 34 in this project's setup, so pin 36 explicitly.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.flbox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("flbox") {
            storeFile = file("flbox.jks")
            storePassword = "flbox-dev"
            keyAlias = "flbox"
            keyPassword = "flbox-dev"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("flbox")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// file_picker 8.x hardcodes compileSdk 34 in its own build script, while
// its flutter_plugin_android_lifecycle dependency requires everything to
// compile against API 36; the app module's compileSdk does not propagate
// to plugin modules. Registering this from the root script is too late
// (":app" is force-evaluated first via evaluationDependsOn, after which
// afterEvaluate registration throws), but this module is evaluated
// before the plugin modules, so the hook still lands in time here.
rootProject.subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.LibraryExtension) {
            androidExt.compileSdk = 36
        }
    }
}
