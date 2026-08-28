import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  root: 'playground',
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
    outDir: '../../../.build/synex_ui/playground',
    emptyOutDir: true,
  },
});
