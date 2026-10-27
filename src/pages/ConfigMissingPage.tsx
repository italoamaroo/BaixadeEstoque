import { AuthLayout } from './AuthLayout';
import { Alert } from '@/components/ui/Card';

export function ConfigMissingPage() {
  return (
    <AuthLayout title="Configuração pendente">
      <Alert tone="warning" title="Variáveis do Supabase não configuradas">
        Defina <code>VITE_SUPABASE_URL</code> e <code>VITE_SUPABASE_ANON_KEY</code> no arquivo <code>.env</code> (local) ou em
        Environment no Render e gere o build novamente. Veja o README, seção 9.
      </Alert>
    </AuthLayout>
  );
}
