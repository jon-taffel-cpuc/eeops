import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router';
// Self-hosted fonts (bundled into /assets). Do NOT switch to a Google Fonts
// <link> or @import -- the SPCS ingress CSP (default-src 'self') blocks it.
import '@fontsource/public-sans/400.css';
import '@fontsource/public-sans/500.css';
import '@fontsource/public-sans/600.css';
import '@fontsource/public-sans/700.css';
import '@fontsource/public-sans/800.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/500.css';
import './index.css';
import App from './App';
import { AuthProvider } from './lib/auth';

// Sign-in is handled by the Snowflake SPCS ingress before this page loads;
// AuthProvider just asks the API who the user is (GET /api/v1/me).
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AuthProvider>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </AuthProvider>
  </StrictMode>,
);
