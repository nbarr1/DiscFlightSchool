# TensorFlow Lite loads delegates and ops reflectively from native code.
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options

# ML Kit pose detection ships its model through reflective loaders.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_pose** { *; }

# kotlinx.serialization keeps generated serializers on the companion.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.discflightschool.** {
    *** Companion;
}
-keepclasseswithmembers class com.discflightschool.** {
    kotlinx.serialization.KSerializer serializer(...);
}
