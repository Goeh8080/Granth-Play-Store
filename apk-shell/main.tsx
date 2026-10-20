/**
 * Entry of the web bundle embedded in the Android app
 * (mobile/android/app/src/main/assets/web/index.html).
 *
 * Same React UI as the website, mounted without the TanStack Start server
 * shell: the APK loads it from file:///android_asset and talks to the
 * Granth API directly. Rebuild with `npm run build:apk`.
 */
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { GranthApp } from "@/components/granth/app";
import "@/styles.css";

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(
    <StrictMode>
      <GranthApp />
    </StrictMode>,
  );
}
