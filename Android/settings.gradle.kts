pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "IssaReader"

// Pure-JVM ports of the Swift packages: the logic, and its tests, with no
// Android types in them.
include(":testing", ":core", ":epub", ":render", ":playback", ":ask")
// Android halves: the design system, the page renderer, the media service,
// the on-device model, and the app itself.
include(":ui", ":render-android", ":playback-android", ":ask-android", ":app")
