# The PDF foreground service is started by name from the manifest and from code;
# keep it (and its Android 15 onTimeout override) exactly as written.
-keep class com.wnm.granthprabandhan.PdfService { *; }
-keep class com.wnm.granthprabandhan.MainActivity { *; }
-keep class com.wnm.granthprabandhan.PageSyncService { *; }
-keep class com.wnm.granthprabandhan.HlFileProvider { *; }
