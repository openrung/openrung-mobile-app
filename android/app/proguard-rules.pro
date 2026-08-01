# OpenRung release keep rules. React Native and most third-party libraries ship their own
# consumer rules; this file covers only the surfaces R8 cannot see into.

# libbox (gomobile bindings): the Go runtime resolves these classes and their members through
# JNI by name — Seq/proxy classes, PlatformInterface callbacks, punch/broker/WSS bindings.
# Shrinking or renaming any of them breaks the tunnel engine at runtime.
-keep class io.nekohasekai.libbox.** { *; }
-keep class go.** { *; }

# kotlinx.serialization: generated serializers are looked up reflectively via the Companion.
# (The runtime artifact ships consumer rules; these pin this app's @Serializable models
# explicitly so an R8 version change can never silently strip them.)
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keep,includedescriptorclasses class com.openrung.**$$serializer { *; }
-keepclassmembers class com.openrung.** {
    *** Companion;
}
-keepclasseswithmembers class com.openrung.** {
    kotlinx.serialization.KSerializer serializer(...);
}
