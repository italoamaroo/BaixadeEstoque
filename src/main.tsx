import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// Modo offline: guarda o app no aparelho para abrir sem internet (somente na versão publicada)
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker
      .register('/sw.js')
      .then(() => navigator.serviceWorker.ready)
      .then((reg) => {
        // a cada abertura com internet, guarda a versão nova do app (só baixa se mudou)
        if (navigator.onLine) reg.active?.postMessage('atualizar-app');
      })
      .catch(() => undefined);
  });
}
