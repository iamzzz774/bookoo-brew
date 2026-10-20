import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

fun requiredKeystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: error("Missing $name in ${keystorePropertiesFile.path}")

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "coffee.bookoo.bookoo_brew"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = requiredKeystoreProperty("keyAlias")
                keyPassword = requiredKeystoreProperty("keyPassword")
                storeFile = rootProject.file(requiredKeystoreProperty("storeFile"))
                storePassword = requiredKeystoreProperty("storePassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "coffee.bookoo.bookoo_brew"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // An existing private signer always takes precedence. Never replace it.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else if (providers.gradleProperty("bookooAllowDebugSigning").orNull == "true") {
                signingConfigs.getByName("debug")
            } else {
                null
            }
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

// Fail only release execution, not configuration of public/debug builds.
gradle.taskGraph.whenReady {
    if (!keystorePropertiesFile.exists() &&
        providers.gradleProperty("bookooAllowDebugSigning").orNull != "true" &&
        allTasks.any { it.project == project && it.name.endsWith("Release") }) {
        error("Release signing requires android/key.properties; for local testing only, " +
            "explicitly pass -PbookooAllowDebugSigning=true (not for distribution).")
    }
}
