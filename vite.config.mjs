import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const rootDir = fileURLToPath(new URL('.', import.meta.url));

// Home + páginas internas (história e painel) no mesmo build.
export default defineConfig({
  appType: 'mpa',
  build: {
    rollupOptions: {
      input: {
        main: new URL('./index.html', import.meta.url).pathname,
        sobre: new URL('./sobre.html', import.meta.url).pathname,
        admin: new URL('./admin.html', import.meta.url).pathname,
      },
    },
  },
  server: {
    fs: { allow: [rootDir] },
  },
});
