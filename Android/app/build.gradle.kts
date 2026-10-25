import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

/**
 * The marketing version is the Apple apps' (`project.yml`), so one release
 * carries one number on every platform. Play's build number is its own
 * counter, in `version.properties`, which `scripts/android-release.sh` raises.
 */
val marketingVersion: String = rootProject.file("../project.yml").readLines()
    .firstNotNullOfOrNull { Regex("""^\s*MARKETING_VERSION:\s*"?([^"\s]+)"?""").find(it)?.groupValues?.get(1) }
    ?: error("MARKETING_VERSION is missing from project.yml")
val buildNumber: Int = Properties()
    .apply { rootProject.file("version.properties").inputStream().use(::load) }
    .getProperty("versionCode").toInt()

/**
 * The upload key's properties file — `storeFile`, `storePassword`, `keyAlias`,
 * `keyPassword` — kept outside the repository: `ISSA_ANDROID_UPLOAD_KEY`, or
 * `~/.android-upload-key.properties`. Without one a release build is unsigned.
 */
val uploadKey: Properties? = (System.getenv("ISSA_ANDROID_UPLOAD_KEY")
    ?: "${System.getProperty("user.home")}/.android-upload-key.properties")
    .let(::File).takeIf { it.isFile }
    ?.let { file -> Properties().apply { file.inputStream().use(::load) } }

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

android {
    namespace = "com.benjaminissa.issareader"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.benjaminissa.issareader"
        minSdk = 31
        targetSdk = 36
        versionName = marketingVersion
        versionCode = buildNumber
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (uploadKey != null) {
            create("upload") {
                storeFile = file(uploadKey.getProperty("storeFile"))
                storePassword = uploadKey.getProperty("storePassword")
                keyAlias = uploadKey.getProperty("keyAlias")
                keyPassword = uploadKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("upload")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    testOptions { unitTests.isIncludeAndroidResources = true }
    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/LICENSE*", "META-INF/NOTICE*")
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

// The unit tests run on this machine's JVM, where the Android build of
// bundled SQLite has no native library to load: its JVM build, which carries
// the host's, stands in, so the device store, every server's store and the
// Ask indexes open real databases, as `:core`'s and `:ask`'s suites do.
configurations.configureEach {
    if (name.endsWith("UnitTestRuntimeClasspath")) exclude(group = "androidx.sqlite", module = "sqlite-bundled-android")
}

dependencies {
    testRuntimeOnly("androidx.sqlite:sqlite-bundled-jvm:${libs.versions.sqlite.get()}")
    implementation(project(":core"))
    implementation(project(":epub"))
    implementation(project(":render"))
    implementation(project(":playback"))
    implementation(project(":ask"))
    implementation(project(":ui"))
    implementation(project(":render-android"))
    implementation(project(":playback-android"))
    implementation(project(":ask-android"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.navigation.compose)
    implementation(libs.core.ktx)
    implementation(libs.core.splashscreen)
    implementation(libs.browser)
    implementation(libs.work.runtime)
    implementation(libs.glance.appwidget)
    implementation(libs.glance.material3)
    implementation(libs.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)
    // The media session and Android Auto (app/media): the session's library
    // service, and the car library's connection state.
    implementation(libs.media3.session)
    implementation(libs.car.app)

    testImplementation(project(":testing"))
    testImplementation(libs.robolectric)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.turbine)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.work.testing)
    testImplementation(libs.media3.test.utils)
    testImplementation(libs.media3.test.utils.robolectric)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
    debugImplementation(libs.compose.ui.test.manifest)

    androidTestImplementation(project(":testing"))
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.uiautomator)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
}
