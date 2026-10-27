import { Link } from 'react-router-dom';
import { EmptyState } from '@/components/ui/Card';
import { SearchX } from 'lucide-react';

export function NotFoundPage() {
  return (
    <EmptyState
      icon={<SearchX className="h-12 w-12" />}
      title="Página não encontrada"
      description="O endereço acessado não existe."
      action={
        <Link to="/" className="font-medium text-brand-700 hover:underline">
          Ir para o painel
        </Link>
      }
    />
  );
}
