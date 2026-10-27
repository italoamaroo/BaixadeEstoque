// Leitura simples do arquivo .env (sem dependências). Usado pelos scripts locais.
import { existsSync, readFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';

export function loadEnv() {
  const env = { ...process.env };
  if (existsSync('.env')) {
    for (const line of readFileSync('.env', 'utf8').split(/\r?\n/)) {
      const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
      if (m && !env[m[1]]) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  const need = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'];
  const missing = need.filter((k) => !env[k]);
  if (missing.length) {
    console.error(`Defina no .env: ${missing.join(', ')}`);
    process.exit(1);
  }
  return env;
}

// ---------------------------------------------------------------------------
// PNG mínimo (RGBA) para a assinatura demonstrativa, sem bibliotecas externas
// ---------------------------------------------------------------------------
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

/** Gera um "rabisco" de assinatura diferente para cada semente. */
export function demoSignaturePng(seed = 1, w = 480, h = 160) {
  const px = Buffer.alloc(w * h * 4, 0);
  const dot = (x, y, r = 2) => {
    for (let dy = -r; dy <= r; dy++)
      for (let dx = -r; dx <= r; dx++) {
        const X = Math.round(x + dx);
        const Y = Math.round(y + dy);
        if (X < 0 || Y < 0 || X >= w || Y >= h || dx * dx + dy * dy > r * r) continue;
        const i = (Y * w + X) * 4;
        px[i] = 15; px[i + 1] = 23; px[i + 2] = 42; px[i + 3] = 255;
      }
  };
  const a = 18 + (seed % 7) * 3;
  const f = 0.045 + (seed % 5) * 0.006;
  let prev = null;
  for (let t = 0; t <= 1; t += 0.0015) {
    const x = 40 + t * (w - 80);
    const y = h / 2 + Math.sin(t * w * f) * a * Math.sin(t * Math.PI) + Math.cos(t * 23 + seed) * 8;
    if (prev) {
      const steps = Math.ceil(Math.hypot(x - prev[0], y - prev[1]));
      for (let s = 0; s <= steps; s++) dot(prev[0] + ((x - prev[0]) * s) / steps, prev[1] + ((y - prev[1]) * s) / steps);
    }
    prev = [x, y];
  }
  for (let x = 60; x < w - 60; x++) dot(x, h - 30 + Math.sin(x / 9 + seed) * 1.5, 1);

  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    px.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
