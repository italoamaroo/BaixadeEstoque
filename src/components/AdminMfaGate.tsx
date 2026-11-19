import { useEffect, useState, type ReactNode } from 'react';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from './ui/Button';
import { Alert, Card } from './ui/Card';
import { Input } from './ui/Field';
import { PageLoader } from './ui/Spinner';
import { errorMessage } from '@/lib/errors';

/** O servidor também exige AAL2. Nenhum segredo TOTP vai para logs ou armazenamento da aplicação. */
export function AdminMfaGate({ children, setup = false }: { children: ReactNode; setup?: boolean }) {
  const { refreshAccess, signOut } = useAuth();
  const [ready, setReady] = useState(false);
  const [loading, setLoading] = useState(true);
  const [factorId, setFactorId] = useState<string | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const inspect = async () => {
    if (!setup) {
      // Implantação em duas etapas: só exigir MFA no app quando o banco já conhece a regra.
      // Após a migração, qualquer erro de rede/permissão continua falhando fechado.
      const { error: policyError } = await supabase.rpc('session_is_aal2');
      if (policyError?.code === 'PGRST202') { setReady(true); return; }
      if (policyError) throw policyError;
    }
    const { data, error: err } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (err) throw err;
    if (data.currentLevel === 'aal2') { setReady(true); return; }
    const { data: factors, error: listError } = await supabase.auth.mfa.listFactors();
    if (listError) throw listError;
    setFactorId(factors.totp.find((f) => f.status === 'verified')?.id ?? null);
  };
  useEffect(() => {
    void inspect().catch((e) => setError(errorMessage(e))).finally(() => setLoading(false));
  }, []);
  const enroll = async () => {
    setBusy(true); setError(null);
    try {
      // Remove apenas cadastros TOTP ainda não confirmados desta conta antes da nova tentativa.
      const { data: factors, error: listError } = await supabase.auth.mfa.listFactors();
      if (listError) throw listError;
      for (const f of factors.all.filter((f) => f.factor_type === 'totp' && f.status === 'unverified')) {
        const { error: removeError } = await supabase.auth.mfa.unenroll({ factorId: f.id });
        if (removeError) throw removeError;
      }
      const { data, error: err } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Baixas de Estoque', issuer: 'Baixas de Estoque' });
      if (err) throw err;
      setFactorId(data.id); setQr(data.totp.qr_code);
    } catch (e) { setError(errorMessage(e)); } finally { setBusy(false); }
  };
  const verify = async () => {
    if (!factorId || !/^\d{6}$/.test(code)) return;
    setBusy(true); setError(null);
    try {
      const { error: err } = await supabase.auth.mfa.challengeAndVerify({ factorId, code });
      if (err) throw err;
      setCode(''); setQr(null);
      await refreshAccess();
      await inspect();
    } catch (e) { setError(errorMessage(e)); } finally { setBusy(false); }
  };
  if (loading) return <PageLoader label="Verificando segundo fator…" />;
  if (ready) return <>{children}</>;
  return <div className="mx-auto mt-12 max-w-md space-y-4 px-4"><Card>
    <h1 className="text-xl font-bold">Proteção da conta administrativa</h1>
    <p className="my-3 text-sm text-slate-600">Use um aplicativo autenticador para verificar o segundo fator antes de acessar o sistema como administrador.</p>
    {qr && <><p className="mb-2 text-sm">Leia este QR Code no autenticador e informe o código. Não compartilhe esta imagem.</p><img src={qr.startsWith('data:') ? qr : `data:image/svg+xml;charset=utf-8,${encodeURIComponent(qr)}`} alt="Cadastro do autenticador" className="mx-auto h-48 w-48" /></>}
    {!factorId ? <Button loading={busy} onClick={() => void enroll()}>Cadastrar autenticador</Button> : <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); void verify(); }}>
      <Input label="Código do autenticador" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" autoComplete="one-time-code" />
      <Button type="submit" loading={busy} disabled={code.length !== 6}>Verificar</Button>
    </form>}
    {error && <div className="mt-3"><Alert tone="error">{error}</Alert><Button variant="ghost" onClick={() => { setLoading(true); void inspect().catch((e) => setError(errorMessage(e))).finally(() => setLoading(false)); }}>Verificar novamente</Button></div>}
    <Button variant="ghost" className="mt-3" onClick={() => void signOut()}>Sair</Button>
  </Card></div>;
}
