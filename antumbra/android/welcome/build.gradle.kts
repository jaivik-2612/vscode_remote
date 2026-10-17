// SPDX-License-Identifier: GPL-3.0-or-later

buildscript {
    repositories {
        mavenCentral()
    }
    dependencies {
        // AGP 9 compiles Kotlin itself ("built-in Kotlin") with the Kotlin
        // Gradle plugin it depends on (2.2.10 for AGP 9.4); this raises it
        // to the pinned Kotlin version, which the Compose compiler plugin
        // below must match.
        classpath(libs.kotlin.gradle.plugin)
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
