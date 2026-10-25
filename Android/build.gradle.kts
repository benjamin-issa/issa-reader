plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.roborazzi) apply false
}

// The repository root, one level up: the Android suites read the Swift
// packages' captured server responses and books in place
// (`Packages/*/Tests/Fixtures`), so every generation's fixtures are checked by
// both clients from one copy.
val repoRoot: File = rootDir.parentFile

// Robolectric's Android runtime, resolved by Gradle (so it is cached, mirrored
// and available offline like every other dependency) instead of downloaded by
// Robolectric itself at test time.
val robolectricRuntime: Configuration by configurations.creating
dependencies { robolectricRuntime(libs.robolectric.android.all) }
val syncRobolectricRuntime by tasks.registering(Sync::class) {
    from(robolectricRuntime)
    into(layout.buildDirectory.dir("robolectric-runtime"))
}

subprojects {
    tasks.withType<Test>().configureEach {
        systemProperty("issa.repoRoot", repoRoot.absolutePath)
        // The release switch (CLAUDE.md): a suite whose input is absent fails
        // instead of skipping.
        providers.environmentVariable("ISSA_RELEASE_RUN").orNull?.let { environment("ISSA_RELEASE_RUN", it) }
        inputs.property("issaReleaseRun", providers.environmentVariable("ISSA_RELEASE_RUN").orElse("0"))
        maxHeapSize = "2g"
        dependsOn(rootProject.tasks.named("syncRobolectricRuntime"))
        systemProperty("robolectric.offline", "true")
        systemProperty("robolectric.dependency.dir", rootProject.layout.buildDirectory.dir("robolectric-runtime").get().asFile.path)
        // Robolectric reaches into FileDescriptor and friends, which JDK 17+
        // only allows when the packages are opened to it.
        jvmArgs(
            "--add-opens=java.base/java.io=ALL-UNNAMED",
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "--add-opens=java.base/java.util=ALL-UNNAMED",
            "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
        )
        testLogging {
            events("failed", "skipped")
            exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        }
    }
}
