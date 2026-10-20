import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { appVersion } from "./vite.config";

const outDir = resolve(__dirname, "mobile/android/app/src/main/assets/web");

function inlineBundle(): Plugin {
  return {
    name: "apk-inline",
    apply: "build",
    closeBundle() {
      const htmlPath = join(outDir, "index.html");
      let html = readFileSync(htmlPath, "utf8");
      html = html.replace(/<link rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g, (_tag, href: string) => {
        const css = readFileSync(join(outDir, href), "utf8");
        return `<style>${css}</style>`;
      });
      html = html.replace(/<script type="module"[^>]*src="([^"]+)"[^>]*><\/script>/g, (_tag, src: string) => {
        const code = readFileSync(join(outDir, src), "utf8");
        return `<script type="module">${code}</script>`;
      });
      writeFileSync(htmlPath, html);
      rmSync(join(outDir, "assets"), { recursive: true, force: true });
    },
  };
}

export default defineConfig({
  root: resolve(__dirname, "apk-shell"),
  base: "./",
  define: {
    "import.meta.env.VITE_APP_VERSION": JSON.stringify(appVersion()),
  },
  worker: {
    format: "es",
  },
  plugins: [react(), tailwindcss(), inlineBundle()],
  resolve: {
    alias: { "@": resolve(__dirname, "src") },
  },
  build: {
    outDir,
    emptyOutDir: true,
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    modulePreload: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
