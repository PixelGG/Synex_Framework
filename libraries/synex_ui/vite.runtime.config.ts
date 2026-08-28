import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  root: 'runtime',
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '@synex/ui': fileURLToPath(new URL('./src/index.ts', import.meta.url)),
    },
  },
  build: {
    target: 'chrome103',
    cssTarget: 'chrome103',
    sourcemap: false,
    outDir: '../web/dist',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 400,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules/react')) return 'react';
          return undefined;
        },
      },
    },
  },
});
