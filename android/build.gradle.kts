group = "com.yollacalls.flutter.voice"
version = "0.1.0"

buildscript {
    val kotlinVersion = "2.4.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.3.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

// The Yolla Voice Android SDK this plugin wraps: one AAR in the Maven repository that is the `maven/` folder of the
// SDK's GitHub repository. A Maven folder `.local-maven/` at the root of the plugin, when there is one, is looked in
// first: an in-house build of the SDK from its sources (tool/build-android-sdk.sh). The app's own modules resolve the
// SDK too (it is on their runtime classpath), hence `rootProject.allprojects`.
val yollaVoiceSdk = "io.yolla:yolla-voice-android:0.1.0"
val yollaVoiceMaven = "https://raw.githubusercontent.com/yolla-io/yolla-voice-android/main/maven"
val localMaven = file("../.local-maven")
rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
        exclusiveContent {
            forRepositories(
                *listOfNotNull(
                    if (localMaven.isDirectory) maven { url = uri(localMaven) } else null,
                    maven { url = uri(yollaVoiceMaven) },
                ).toTypedArray(),
            )
            filter { includeGroup("io.yolla") }
        }
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.yollacalls.flutter.voice"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // The SDK's floor.
        minSdk = 26
    }

    testOptions {
        unitTests {
            all {
                it.useJUnitPlatform()
                it.testLogging {
                    events("skipped", "failed")
                    exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(yollaVoiceSdk)
    // Telecom's self-managed calls on every API level the SDK supports.
    implementation("androidx.core:core-telecom:1.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // Only to read the destination out of the call token; the SDK brings the same library.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
}
