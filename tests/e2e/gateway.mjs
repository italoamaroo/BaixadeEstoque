// Gateway local que imita o Supabase (Auth/Storage mínimos) e repassa /rest/v1 ao PostgREST.
// SOMENTE PARA TESTE LOCAL. Não usar em produção.
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const SECRET = 'segredo-local-de-teste-com-mais-de-32-caracteres';
const FILES = process.env.E2E_FILES ?? new URL('./.arquivos', import.meta.url).pathname;
fs.mkdirSync(FILES, { recursive: true });
const USERS = {
  'admin@teste.local': '00000000-0000-0000-0000-00000000000a',
  'almox.mur@teste.local': '00000000-0000-0000-0000-0000000000a1',
  'sa@teste.local': '00000000-0000-0000-0000-0000000000b1',
  'gestor@teste.local': '00000000-0000-0000-0000-0000000000c1',
};
const b64u = (b) => Buffer.from(b).toString('base64url');
export function sign(payload) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify(payload));
  const s = crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${s}`;
}
function decode(tok) {
  try {
    return JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString());
  } catch {
    return null;
  }
}
function session(email) {
  const id = USERS[email];
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const user = { id, email, aud: 'authenticated', role: 'authenticated', user_metadata: {}, app_metadata: {}, created_at: new Date().toISOString() };
  return {
    access_token: sign({ sub: id, email, role: 'authenticated', aud: 'authenticated', exp }),
    token_type: 'bearer',
    expires_in: 3600,
    expires_at: exp,
    refresh_token: `r-${email}`,
    user,
  };
}
function psqlAs(uid, sql) {
  const claims = JSON.stringify({ sub: uid, role: 'authenticated' }).replace(/'/g, "''");
  const full = `begin; set local role authenticated; select set_config('request.jwt.claims', '${claims}', true); ${sql}; commit;`;
  return execFileSync('psql', ['-h', '/tmp', '-p', process.env.PGPORT ?? '54329', '-U', 'postgres', '-d', process.env.PGDATABASE ?? 'e2e', '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', full], { encoding: 'utf8' });
}
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,PUT,DELETE,OPTIONS,HEAD',
  'Access-Control-Expose-Headers': 'Content-Range, Content-Location, Location',
};
function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...cors, ...headers });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
function readBody(req) {
  return new Promise((r) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => r(Buffer.concat(chunks)));
  });
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    if (req.method === 'OPTIONS') return send(res, 204, '', { 'Access-Control-Allow-Headers': req.headers['access-control-request-headers'] ?? '*' });
    const body = await readBody(req);
    const auth = (req.headers.authorization ?? '').replace('Bearer ', '');
    const claims = decode(auth);

    if (url.pathname.startsWith('/rest/v1')) {
      const target = url.pathname.replace('/rest/v1', '') + url.search;
      const headers = { ...req.headers };
      delete headers.host;
      const p = http.request({ host: '127.0.0.1', port: 3000, path: target, method: req.method, headers }, (pr) => {
        const h = Object.fromEntries(Object.entries(pr.headers).filter(([k]) => !k.startsWith('access-control-')));
        res.writeHead(pr.statusCode, { ...h, ...cors });
        pr.pipe(res);
      });
      p.end(body);
      return;
    }

    if (url.pathname === '/auth/v1/token') {
      const j = JSON.parse(body.toString() || '{}');
      const grant = url.searchParams.get('grant_type');
      if (grant === 'password') {
        if (!USERS[j.email] || j.password !== 'teste123') return send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
        return send(res, 200, session(j.email));
      }
      if (grant === 'refresh_token') return send(res, 200, session(String(j.refresh_token).slice(2)));
    }
    if (url.pathname === '/auth/v1/user') {
      if (!claims) return send(res, 401, { msg: 'invalid JWT' });
      return send(res, 200, { id: claims.sub, email: claims.email, aud: 'authenticated', role: 'authenticated', user_metadata: {}, app_metadata: {} });
    }
    if (url.pathname === '/auth/v1/logout') return send(res, 204, '');
    if (url.pathname === '/auth/v1/recover') return send(res, 200, {});

    const up = /^\/storage\/v1\/object\/(assinaturas)\/(.+)$/.exec(url.pathname);
    if (up && req.method === 'POST') {
      const [, bucket, name] = up;
      const n = decodeURIComponent(name);
      try {
        psqlAs(claims.sub, `insert into storage.objects (bucket_id, name, owner, metadata) values ('${bucket}', '${n.replace(/'/g, "''")}', '${claims.sub}', '{"size": ${body.length}, "mimetype": "image/png"}')`);
      } catch (e) {
        const dup = /duplicate key/.test(String(e.stderr));
        return send(res, dup ? 409 : 403, { statusCode: dup ? '409' : '403', error: dup ? 'Duplicate' : 'Unauthorized', message: dup ? 'The resource already exists' : 'new row violates row-level security policy' });
      }
      fs.mkdirSync(path.dirname(path.join(FILES, bucket, n)), { recursive: true });
      // supabase-js envia multipart quando o corpo é Blob/FormData; extrai o PNG
      const start = body.indexOf(Buffer.from([0x89, 0x50, 0x4e, 0x47]));
      fs.writeFileSync(path.join(FILES, bucket, n), start >= 0 ? body.subarray(start) : body);
      return send(res, 200, { Key: `${bucket}/${n}`, Id: crypto.randomUUID() });
    }
    const sg = /^\/storage\/v1\/object\/sign\/(assinaturas)\/(.+)$/.exec(url.pathname);
    if (sg && req.method === 'POST') {
      const n = decodeURIComponent(sg[2]);
      const out = psqlAs(claims.sub, `select count(*) from storage.objects where bucket_id='assinaturas' and name='${n.replace(/'/g, "''")}'`).trim().split('\n').pop();
      if (out !== '1') return send(res, 400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      return send(res, 200, { signedURL: `/object/sign/assinaturas/${sg[2]}?token=ok` });
    }
    if (sg && req.method === 'GET') {
      const file = path.join(FILES, 'assinaturas', decodeURIComponent(sg[2]));
      if (!fs.existsSync(file)) return send(res, 404, { message: 'not found' });
      return send(res, 200, fs.readFileSync(file), { 'Content-Type': 'image/png' });
    }
    send(res, 404, { message: `não simulado: ${req.method} ${url.pathname}` });
  })
  .listen(54321, () => console.log('gateway em http://localhost:54321'));
