import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { toast } from 'sonner';
import { KeyRound } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { PageLoader } from '@/components/ui/Spinner';
import { passwordSchema } from '@/lib/validation';
import { errorMessage } from '@/lib/errors';
import { AuthLayout } from './AuthLayout';

/** Página aberta pelo link de recuperação enviado por e-mail. */
export function ResetPasswordPage() {
  const { session, loading, clearRecovery } = useAuth();
  const navigate = useNavigate();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (loading) return <PageLoader />;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const r = passwordSchema.safeParse(password);
    if (!r.success) return setError(r.error.issues[0].message);
    if (password !== confirm) return setError('As senhas não conferem.');
    setBusy(true);
    setError(null);
    try {
      const { error: err } = await supabase.auth.updateUser({ password });
      if (err) throw err;
      clearRecovery();
      toast.success('Senha alterada com sucesso.');
      navigate('/', { replace: true });
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout title="Nova senha" subtitle="Crie uma senha com pelo menos 8 caracteres, letras e números.">
      {!session ? (
        <Alert tone="warning" title="Link inválido ou expirado">
          Solicite um novo link em “Esqueci minha senha”.
        </Alert>
      ) : (
        <form className="space-y-4" onSubmit={submit} noValidate>
          <Input label="Nova senha" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} inputSize="lg" />
          <Input label="Confirmar nova senha" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} inputSize="lg" />
          {error && <Alert tone="error">{error}</Alert>}
          <Button type="submit" size="lg" block loading={busy} icon={<KeyRound className="h-5 w-5" />}>
            Salvar nova senha
          </Button>
        </form>
      )}
    </AuthLayout>
  );
}
