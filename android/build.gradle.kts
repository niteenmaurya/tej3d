plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.thropix.tej3d"
version = "0.34.0"

android {
    namespace = "com.thropix.tej3d"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        externalNativeBuild {
            cmake {
                cppFlags("-std=c++17", "-fno-exceptions", "-fno-rtti")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
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
