plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "codes.liamzhao.javhub_desktop"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "codes.liamzhao.javhub"
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

    // Every build must carry the same certificate, or Android refuses to install it over the
    // copy on the phone. CI names its keystore in JAVHUB_KEYSTORE (the same key as this PC's
    // ~/.android/debug.keystore); a local build without it signs with that debug key.
    val javhubKeystore = System.getenv("JAVHUB_KEYSTORE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (javhubKeystore != null) {
            create("javhub") {
                storeFile = javhubKeystore
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (javhubKeystore != null) "javhub" else "debug")
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

dependencies {
    // FileProvider: hands a downloaded update to the system installer
    implementation("androidx.core:core:1.13.1")
}
