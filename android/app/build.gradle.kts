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

// The routing rule databases ship inside the APK instead of being
// downloaded on the phone at first use: fetch them at build time
// into src/main/assets/geo/, from where MainActivity copies them out
// of the bundled assets on first run. Fails the build loudly when no
// mirror yields a sane file, so a rules-less APK never ships silent.
val geoAssetsDir = layout.projectDirectory.dir("src/main/assets/geo")
val downloadGeoData by tasks.registering {
    outputs.dir(geoAssetsDir)
    doLast {
        val sources = mapOf(
            "geoip.dat" to listOf(
                "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat",
                "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
            ),
            "geosite.dat" to listOf(
                "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat",
                "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
            )
        )
        val dir = geoAssetsDir.asFile
        dir.mkdirs()
        for ((name, urls) in sources) {
            val target = java.io.File(dir, name)
            if (target.exists() && target.length() > 1_000_000) continue
            var ok = false
            for (url in urls) {
                try {
                    val tmp = java.io.File(dir, "$name.tmp")
                    java.net.URL(url).openStream().use { input ->
                        tmp.outputStream().use { output -> input.copyTo(output) }
                    }
                    if (tmp.length() > 1_000_000) {
                        tmp.renameTo(target)
                        ok = true
                        break
                    }
                    tmp.delete()
                } catch (e: Exception) {
                    logger.warn("geo data download failed from $url: ${e.message}")
                }
            }
            if (!ok) {
                throw GradleException("Could not download $name for the bundled rule databases")
            }
        }
    }
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("Assets")) {
        dependsOn(downloadGeoData)
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
