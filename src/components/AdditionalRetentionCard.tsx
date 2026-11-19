import { useEffect, useState } from 'react';
import { getAdditionalRetentionSummary, type AdditionalRetentionSummary } from '@/lib/api';
import { fmtDateTime, fmtInt } from '@/lib/format';
import { errorMessage } from '@/lib/errors';
import { Alert, Card, CardHeader } from './ui/Card';

const labels: Record<string, string> = {
  cadastros_faciais: 'Cadastros faciais (atuais e arquivados)',
  logs: 'Logs da aplicação sem vínculo com ME', tentativas_faciais: 'Tentativas faciais', backups: 'Backups registrados',
};
export function AdditionalRetentionCard() {
  const [data, setData] = useState<AdditionalRetentionSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let current = true;
    void getAdditionalRetentionSummary().then(v => { if (current) setData(v); }).catch(e => {
      if (current) setError(/PGRST202|schema cache|could not find.*function/i.test(String(e?.message))
        ? 'A guarda adicional depende da migração 29 no Supabase.' : errorMessage(e));
    });
    return () => { current = false; };
  }, []);
  return <Card>
    <CardHeader title="Guarda de cadastros faciais, logs e dados offline" />
    {error ? <Alert tone="warning">{error}</Alert> : !data ? <p>Consultando política de guarda…</p> : <div className="space-y-3 text-sm">
      <p><strong>{data.years} anos desde a criação</strong>. Sem exclusão automática. O fim do prazo exige revisão.</p>
      <p>Modelos removidos ou de funcionários inativos ficam arquivados e não participam do reconhecimento.</p>
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
        <thead><tr><th>Categoria</th><th>Registros</th><th>Revisar</th><th>Próximo fim de prazo</th></tr></thead>
        <tbody>{Object.entries(labels).map(([key, label]) => {
          const c = data.categories[key];
          return <tr key={key}><td className="py-2">{label}</td><td>{fmtInt(c?.total ?? 0)}</td><td>{fmtInt(c?.review_due ?? 0)}</td><td>{fmtDateTime(c?.next_review_at)}</td></tr>;
        })}</tbody>
      </table></div>
      <p>Saídas offline não enviadas: 10 anos desde a criação no aparelho. Após o envio, registro e assinatura seguem a guarda da ME. Cópias de consulta e de acesso continuam temporárias.</p>
      <Alert tone="warning">Backups: o inventário não comprova que as cópias externas continuam disponíveis. Configure o armazenamento por 10 anos, execute o backup e teste a restauração. A migração não altera a retenção do Supabase ou do Render, nem de logs nativos dos provedores.</Alert>
    </div>}
  </Card>;
}
