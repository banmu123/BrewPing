# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in the SDK tools directory.

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }

# Keep model classes
-keep class com.brewping.android.model.** { *; }
