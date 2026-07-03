import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig, type Plugin } from "vite";

function htmlPlugin(): Plugin {
    return {
        name: "macfolio-html",
        generateBundle() {
            this.emitFile({
                type: "asset",
                fileName: "index.html",
                source: readFileSync(resolve(__dirname, "index.html"), "utf8"),
            });
        },
    };
}

export default defineConfig({
    plugins: [htmlPlugin()],
    define: {
        "process.env.NODE_ENV": JSON.stringify("production"),
    },
    build: {
        outDir: resolve(__dirname, "../../build/editor"),
        emptyOutDir: true,
        assetsInlineLimit: Number.MAX_SAFE_INTEGER,
        cssCodeSplit: false,
        lib: {
            entry: resolve(__dirname, "index.ts"),
            formats: ["iife"],
            name: "MacfolioEditor",
            fileName() {
                return "index.js";
            },
        },
        rollupOptions: {
            output: {
                assetFileNames(asset) {
                    const index = asset.names?.some((name) => {
                        return name.endsWith(".css");
                    });

                    if (index) {
                        return "index.css";
                    }

                    return "[name][extname]";
                },
            },
        },
    },
});
