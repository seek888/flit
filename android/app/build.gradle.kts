import java.util.Properties

plugins {
    id("com.android.application")
    // AGP 9 内置 Kotlin，app 不再显式应用 org.jetbrains.kotlin.android。
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名: android/key.properties 存在时启用(密钥库文件不入库);
// 缺失时回退 debug 签名, 保证无密钥环境也能出包
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystorePropertiesFile.exists() &&
    keystoreProperties["storePassword"] != null

android {
    namespace = "cc.lycstar.flit"
    compileSdk = flutter.compileSdkVersion
    // 钉在设备端已安装的 NDK(与 lib/setup_runner.dart 的 ndkVersion 常量一致),
    // 不用 flutter.ndkVersion, 避免设备端因缺新版 NDK 而构建失败
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.seek888.flit"
        // Termux 环境要求: exec 数据目录二进制需要 targetSdk<=28;
        // pty/bootstrap 依赖 minSdk 24
        minSdk = 24
        //noinspection ExpiredTargetSdkVersion
        targetSdk = 28
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
    }
    lint {
        // targetSdk 28 是 Termux W^X 硬约束(应用数据目录可 exec),
        // 侧载分发不上架 Play, Google Play 的过期 API 检查不适用
        disable += "ExpiredTargetSdkVersion"
    }

    packaging {
        // 原生库必须解包成真实文件(Termux 环境直接 exec 数据目录二进制)
        jniLibs.useLegacyPackaging = true
        // debug 构建默认打入的 Vulkan 校验层(14MB)对本项目无用, 排除
        jniLibs.excludes += "lib/*/libVkLayer_khronos_validation.so"
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            // debug/release 共用同一密钥库, 调试包与正式包可互相覆盖安装
            getByName("debug") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            if (hasReleaseKeystore) signingConfig = signingConfigs.getByName("debug")
        }
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // 无密钥环境回退 debug 签名
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

// AGP 内置 Kotlin 的 JVM 目标对齐 Java 17
// (扩展块会被 FGP 后置覆盖, 用 task 级配置确保生效)
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
