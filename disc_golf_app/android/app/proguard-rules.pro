# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# File Picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# TFLite
-keep class org.tensorflow.lite.** { *; }

# Google ML Kit
-keep class com.google.mlkit.** { *; }

# FFmpeg Kit
-keep class com.arthenica.ffmpegkit.** { *; }

# Gal (gallery access)
-keep class app.galeria.** { *; }

# Google Play Core (referenced by Flutter deferred components)
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
