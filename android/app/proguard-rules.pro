# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# CloudBase
-keep class com.tencent.cloudbase.** { *; }

# WebView
-keep class android.webkit.** { *; }

# audioplayers
-keep class xyz.luan.audioplayers.** { *; }

# pdf
-keep class com.itextpdf.** { *; }

# Play Core - ignore missing classes (not used directly)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# Do not strip any native method names
-keepclasseswithmembernames class * {
    native <methods>;
}
