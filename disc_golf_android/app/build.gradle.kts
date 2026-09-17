import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Release builds require a complete signing config. Without one the build is
// stopped outright (see the task graph check below) rather than producing an
// unsigned artifact the Play Console would reject on upload.
val keystoreProperties = Properties().apply {
    val keystoreFile = rootProject.file("key.properties")
    if (keystoreFile.exists()) {
        keystoreFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { keystoreProperties.getProperty(it)?.isNotBlank() == true }

// An unsigned release build succeeds and produces an artifact nobody can
// upload, and CI only ever builds debug, so nothing else would catch it.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { task ->
        task.project == project &&
            listOf("assembleRelease", "bundleRelease", "packageRelease", "installRelease")
                .any { task.name.startsWith(it) }
    }
    if (buildsRelease && !hasReleaseSigning) {
        throw GradleException(
            "Release builds need signing credentials. Add disc_golf_android/key.properties " +
                "with storeFile, storePassword, keyAlias and keyPassword, or build the debug " +
                "variant instead.",
        )
    }
}

android {
    namespace = "com.discflightschool.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.discflightschool.app"
        minSdk = 24
        targetSdk = 36
        // Increment versionCode on every release submitted to Google Play: the
        // console rejects a re-upload whose build number does not increase.
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // java.time on API 24, without raising minSdk to 26.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    androidResources {
        // The detector is already compressed; letting aapt deflate it would
        // force a full decompress into memory before the interpreter can map it.
        noCompress += "tflite"
    }

    sourceSets {
        getByName("main") {
            kotlin.srcDir("src/main/kotlin")
        }
        getByName("test") {
            kotlin.srcDir("src/test/kotlin")
        }
    }

    testOptions {
        unitTests {
            // The helpers under test are Android-free, but they live in classes
            // whose initializers touch android.graphics. Returning defaults
            // keeps those initializers from throwing before the test runs.
            isReturnDefaultValues = true
        }
    }

    tasks.withType<Test>().configureEach {
        // Release builds fail without a key.properties; unit tests must not.
        systemProperty("robolectric.enabledSdks", "")
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.navigation.compose)

    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.ui)
    implementation(libs.androidx.media3.common)
    implementation(libs.androidx.media3.transformer)
    implementation(libs.androidx.media3.effect)

    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.documentfile)

    implementation(libs.mlkit.pose.detection.accurate)
    implementation(libs.tensorflow.lite)
    implementation(libs.tensorflow.lite.gpu)
    implementation(libs.tensorflow.lite.gpu.api)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.3")

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)

    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
