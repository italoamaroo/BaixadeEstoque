import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Mail } from 'lucide-react';
import { Button } from '@/components/ui/Button';
import { Input } from '@/components/ui/Field';
import { Alert } from '@/components/ui/Card';
import { sendPasswordReset } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { AuthLayout } from './AuthLayout';

export function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!/^\S+@\S+\.\S+$/.test(email.trim())) {
      setError('Informe um e-mail válido.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await sendPasswordReset(email.trim().toLowerCase());
      setSent(true);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout title="Recuperar senha" subtitle="Enviaremos um link para você criar uma nova senha.">
      {sent ? (
        <div className="space-y-4">
          <Alert tone="success" title="Verifique seu e-mail">
            Se o endereço estiver cadastrado, você receberá o link de redefinição em alguns minutos.
          </Alert>
          <Link to="/login" className="block text-center text-sm font-medium text-brand-700 hover:underline">
            Voltar para o login
          </Link>
        </div>
      ) : (
        <form className="space-y-4" onSubmit={submit} noValidate>
          <Input label="E-mail" type="email" value={email} onChange={(e) => setEmail(e.target.value)} inputSize="lg" required autoComplete="username" />
          {error && <Alert tone="error">{error}</Alert>}
          <Button type="submit" size="lg" block loading={busy} icon={<Mail className="h-5 w-5" />}>
            Enviar link
          </Button>
          <Link to="/login" className="block text-center text-sm font-medium text-brand-700 hover:underline">
            Voltar para o login
          </Link>
        </form>
      )}
    </AuthLayout>
  );
}
