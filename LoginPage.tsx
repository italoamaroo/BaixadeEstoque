import { useState } from 'react';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { LogIn } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { errorMessage } from '@/lib/errors';
import { AuthLayout } from './AuthLayout';

export function LoginPage() {
  const { session, signIn, loading } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const from = (location.state as { from?: string } | null)?.from ?? '/';
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (session && !loading) return <Navigate to={from} replace />;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    if (!email.trim() || !password) {
      setError('Informe e-mail e senha.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await signIn(email, password);
      navigate(from, { replace: true });
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout title="Entrar" subtitle="Use o e-mail e a senha cadastrados pelo administrador.">
      <form className="space-y-4" onSubmit={submit} noValidate>
        <Input label="E-mail" type="email" autoComplete="username" inputMode="email" value={email} onChange={(e) => setEmail(e.target.value)} inputSize="lg" required />
        <Input label="Senha" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} inputSize="lg" required />
        {error && <Alert tone="error">{error}</Alert>}
        <Button type="submit" size="lg" block loading={busy} icon={<LogIn className="h-5 w-5" />}>
          Entrar
        </Button>
        <p className="text-center text-sm">
          <Link to="/recuperar-senha" className="font-medium text-brand-700 hover:underline">
            Esqueci minha senha
          </Link>
        </p>
      </form>
    </AuthLayout>
  );
}
