import { readFileSync } from 'node:fs';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// Single source of truth for the app version: frontend/package.json.
// deploy/01_auto_deploy_sf.sh bumps it (and eeops/__init__.py) on every deploy.
const { version } = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf-8'));

// Writes dist/version.json; deploy/02_build_image_laptop.py refuses to ship a
// static/ bundle whose version.json doesn't match package.json.
function versionFile(): Plugin {
  return {
    name: 'eeops-version-file',
    generateBundle() {
      this.emitFile({
        type: 'asset',
        fileName: 'version.json',
        source: JSON.stringify({ version, built: new Date().toISOString() }) + '\n',
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), versionFile()],
  define: {
    __APP_VERSION__: JSON.stringify(version),
  },
  build: {
    // The SPCS ingress sends CSP default-src 'self'. Vite inlines small assets
    // (fonts, images) as data: URIs by default, which that policy blocks, so
    // always emit them as files under /assets instead.
    assetsInlineLimit: 0,
  },
  server: {
    // Local dev: `uvicorn api.main:app --port 8000` with EEOPS_DEV_USER set.
    proxy: {
      '/api': 'http://localhost:8000',
    },
  },
});
