import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    id("dev.flutter.flutter-gradle-plugin")
}

// Leer key.properties si existe (no existe en CI sin secrets configurados)
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "com.coopertrans.movil"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }


    signingConfigs {
        create("release") {
            keyAlias = keyProperties["keyAlias"] as String? ?: System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = keyProperties["keyPassword"] as String? ?: System.getenv("ANDROID_KEY_PASSWORD")
            storeFile = keyProperties["storeFile"]?.let { file(it) }
                ?: System.getenv("ANDROID_KEYSTORE_PATH")?.let { file(it) }
            storePassword = keyProperties["storePassword"] as String? ?: System.getenv("ANDROID_STORE_PASSWORD")
        }
    }

    defaultConfig {
        applicationId = "com.coopertrans.movil"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // androidx.activity 1.8+ trae enableEdgeToEdge() para opt-in explícito
    // al comportamiento edge-to-edge de Android 15+ (Play Console warning
    // "es posible que la pantalla de borde a borde no se muestre para
    // todos los usuarios"). Llamado desde MainActivity.onCreate().
    implementation("androidx.activity:activity-ktx:1.9.3")
}
