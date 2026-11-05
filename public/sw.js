/* Service worker do Baixas de Estoque: permite abrir o sistema sem internet.
 * - Páginas: tenta a rede primeiro (sempre a versão mais nova); sem rede, usa a cópia guardada.
 * - Arquivos do app (/assets): guardados no aparelho na instalação (lista em /asset-list.json).
 * - Supabase e outros domínios: nunca passam por aqui (dados sempre do servidor).
 */
const CACHE = 'baixas-app-v2';

async function precache() {
  const cache = await caches.open(CACHE);
  await cache.add(new Request('/index.html', { cache: 'reload' }));
  try {
    const res = await fetch('/asset-list.json', { cache: 'no-store' });
    const { build, files } = await res.json();
    const prev = await cache.match('/__build', { ignoreVary: true });
    if (prev && (await prev.text()) === String(build)) return; // já guardado
    const urls = files.filter((f) => !f.endsWith('.html')).map((f) => '/' + f);
    // guarda em lotes para não estourar a rede do celular
    for (let i = 0; i < urls.length; i += 10) {
      await Promise.all(urls.slice(i, i + 10).map((u) => cache.add(u).catch(() => undefined)));
    }
    // remove arquivos de versões antigas
    const keep = new Set([...urls, '/index.html', '/'].map((u) => new URL(u, self.location.origin).href));
    for (const req of await cache.keys()) {
      if (new URL(req.url).pathname.startsWith('/assets/') && !keep.has(req.url)) await cache.delete(req);
    }
    await cache.put('/__build', new Response(String(build)));
  } catch {
    /* sem a lista, os arquivos são guardados conforme o uso */
  }
}

self.addEventListener('install', (event) => {
  event.waitUntil(precache().then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('message', (event) => {
  if (event.data === 'atualizar-app') event.waitUntil(precache());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Navegação (qualquer rota do app): rede primeiro, cópia do index.html sem internet
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put('/index.html', copy));
          }
          return res;
        })
        .catch(() => caches.match('/index.html', { ignoreVary: true })),
    );
    return;
  }

  // Arquivos com hash no nome: cópia local primeiro
  if (url.pathname.startsWith('/assets/')) {
    event.respondWith(
      // ignoreVary: scripts de módulo vêm com cabeçalho Origin e o servidor pode responder com "Vary"
      caches.match(req.url, { ignoreVary: true }).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (res.ok) {
              const copy = res.clone();
              caches.open(CACHE).then((c) => c.put(req, copy));
            }
            return res;
          }),
      ),
    );
    return;
  }

  // Demais arquivos do site (ícone etc.): rede primeiro, cópia sem internet
  if (url.pathname === '/sw.js' || url.pathname === '/asset-list.json') return;
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req.url, { ignoreVary: true })),
  );
});
