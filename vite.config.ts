import { readFileSync } from "node:fs";
import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import viteReact from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { nitro } from "nitro/vite";

/** App version shown in Settings; same file Gradle reads (mobile/version.properties). */
export function appVersion(): string {
  try {
    const text = readFileSync(new URL("./mobile/version.properties", import.meta.url), "utf8");
    return /^VERSION_NAME=(.+)$/m.exec(text)?.[1]?.trim() || "0.0.0";
  } catch {
    return "0.0.0";
  }
}

export default defineConfig(({ command, isPreview }) => ({
  define: {
    "import.meta.env.VITE_APP_VERSION": JSON.stringify(appVersion()),
  },
  server: {
    host: "0.0.0.0",
    port: 8080,
    strictPort: true,
  },
  preview: {
    host: "127.0.0.1",
    port: 8081,
    strictPort: true,
  },
  resolve: { tsconfigPaths: true },
  plugins: [
    tailwindcss(),
    tanstackStart(),
    ...(command === "build" || isPreview
      ? [
          nitro({
            preset: "vercel",
          }),
        ]
      : []),
    viteReact(),
  ],
}));
