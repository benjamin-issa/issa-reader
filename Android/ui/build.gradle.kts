import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

android {
    namespace = "com.benjaminissa.issareader.ui"
    compileSdk = 37
    defaultConfig {
        minSdk = 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    testOptions { unitTests.isIncludeAndroidResources = true }
}

// The bundled faces and their licences, shared with the Swift package
// (Packages/IssaUI/Sources/IssaUI/Resources/Fonts) rather than copied into the
// repository twice. The faces become font resources (`R.font.literata_regular`)
// so Compose, the page renderer and the widget can all reach them without a
// Context; the licences become assets for the licences screen.
abstract class SharedFontsTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fonts: DirectoryProperty

    @get:OutputDirectory
    abstract val resDir: DirectoryProperty

    @get:OutputDirectory
    abstract val assetsDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val res = resDir.get().asFile.resolve("font").apply { deleteRecursively(); mkdirs() }
        val assets = assetsDir.get().asFile.resolve("Fonts").apply { deleteRecursively(); mkdirs() }
        fonts.get().asFile.listFiles().orEmpty().sortedBy { it.name }.forEach { file ->
            when (file.extension.lowercase()) {
                // A resource name is lowercase letters, digits and underscores:
                // `SourceSerif4-Regular.ttf` becomes `R.font.sourceserif4_regular`.
                "ttf", "otf" -> file.copyTo(
                    res.resolve(file.nameWithoutExtension.lowercase().replace(Regex("[^a-z0-9]"), "_") + "." + file.extension.lowercase()),
                )
                "txt" -> file.copyTo(assets.resolve(file.name))
            }
        }
    }
}

val sharedFonts = tasks.register<SharedFontsTask>("sharedFonts") {
    fonts.set(rootDir.parentFile.resolve("Packages/IssaUI/Sources/IssaUI/Resources/Fonts"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.res?.addGeneratedSourceDirectory(sharedFonts, SharedFontsTask::resDir)
        variant.sources.assets?.addGeneratedSourceDirectory(sharedFonts, SharedFontsTask::assetsDir)
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(project(":core"))
    api(project(":render"))
    api(libs.core.ktx)
    api(platform(libs.compose.bom))
    api(libs.compose.ui)
    api(libs.compose.foundation)
    api(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    testImplementation(project(":testing"))
    testImplementation(libs.robolectric)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
}
