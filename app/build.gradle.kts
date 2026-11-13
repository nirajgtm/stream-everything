import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// xtream.properties is optional. With no Xtream credentials the app asks for them
// on first run (Settings > Xtream account), which is how public/release builds ship;
// baking them in just pre-fills that account for a personal build.
val xtreamProps = Properties().apply {
    val file = rootProject.file("xtream.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun xtream(key: String): String = xtreamProps.getProperty(key) ?: ""

fun xtreamOptional(key: String): String = xtreamProps.getProperty(key) ?: ""

android {
    namespace = "com.nirajgtm.xtreamtv"
    compileSdk = 33

    defaultConfig {
        applicationId = "com.nirajgtm.xtreamtv"
        minSdk = 21
        targetSdk = 33
        versionCode = 64
        versionName = "0.34.2"

        buildConfigField("String", "XTREAM_SERVER", "\"${xtream("XTREAM_SERVER")}\"")
        buildConfigField("String", "XTREAM_USER", "\"${xtream("XTREAM_USER")}\"")
        buildConfigField("String", "XTREAM_PASS", "\"${xtream("XTREAM_PASS")}\"")
        buildConfigField("String", "TMDB_KEY", "\"${xtreamOptional("TMDB_KEY")}\"")
        buildConfigField("String", "WATCHMODE_KEY", "\"${xtreamOptional("WATCHMODE_KEY")}\"")
    }

    buildTypes {
        debug {
            // A debuggable app is interpreted with extra JNI checking, which makes the
            // whole UI several times slower on a Chromecast. Build with -Pdebuggable
            // only when a debugger or run-as is actually needed.
            isDebuggable = project.hasProperty("debuggable")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.11.0")
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("androidx.media3:media3-exoplayer:1.1.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.1.1")
    implementation("androidx.media3:media3-ui:1.1.1")
}
