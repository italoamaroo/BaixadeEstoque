import { useEffect, useState } from 'react';
import { getMovementRetention, getMovementRetentionSummary, type MovementRetention, type MovementRetentionSummary } from '@/lib/api';
import { fmtDateTime, fmtInt } from '@/lib/format';
import { errorMessage } from '@/lib/errors';
import { Alert, Card, CardHeader } from './ui/Card';

/** Mostra a política lida do banco, sem simular que a migração já está aplicada. */
export function MovementRetentionCard({ movementId }: { movementId?: string }) {
  const [data, setData] = useState<MovementRetention | MovementRetentionSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let current = true;
    setData(null); setError(null);
    const request = movementId ? getMovementRetention(movementId) : getMovementRetentionSummary();
    void request.then((v) => { if (current) setData(v); }).catch((e) => {
      if (current) setError(/PGRST202|schema cache|could not find.*function/i.test(String(e?.message))
        ? 'A política de guarda de MEs depende da migração 28 no Supabase.' : errorMessage(e));
    });
    return () => { current = false; };
  }, [movementId]);
  return <Card>
    <CardHeader title="Guarda de MEs e comprovantes" subtitle="Itens, registros de SA, fotos e assinaturas vinculados à movimentação." />
    {error ? <Alert tone="warning">{error}</Alert> : !data ? <p className="text-sm text-slate-500">Consultando prazo de guarda…</p> : <div className="space-y-3 text-sm">
      <p><strong>{data.years} anos</strong> a partir da conclusão da ME ou, nas canceladas, da data do cancelamento.</p>
      {'movement_id' in data ? <>
        <p>Marco: {data.basis_event === 'conclusao' ? 'conclusão' : data.basis_event === 'cancelamento' ? 'cancelamento' : 'aguardando encerramento'} · {fmtDateTime(data.started_at)}</p>
        <p>Fim do prazo de guarda: <strong>{fmtDateTime(data.retain_until)}</strong></p>
        {data.state === 'data_de_encerramento_ausente' && <Alert tone="warning">A ME está encerrada, mas não possui data de encerramento. É necessária conferência antes de calcular o prazo.</Alert>}
        {data.state === 'revisao_pendente' && <Alert tone="warning">Prazo cumprido. Revisar a necessidade de conservação e eventuais impedimentos antes de qualquer descarte.</Alert>}
      </> : <div className="grid gap-3 sm:grid-cols-3">
        <p>Em guarda: <strong>{fmtInt(data.retained)}</strong></p>
        <p>Aguardando encerramento: <strong>{fmtInt(data.awaiting_closure)}</strong></p>
        <p>Prazo cumprido, revisar: <strong>{fmtInt(data.review_due)}</strong></p>
        {data.missing_date>0 && <p className="text-amber-800">Sem data de encerramento: {fmtInt(data.missing_date)}</p>}
        <p className="sm:col-span-3">Próximo fim de prazo: {fmtDateTime(data.next_review_at)}</p>
      </div>}
      <p className="text-xs text-slate-500">Sem exclusão automática. Esta regra não altera a retenção de cadastros faciais, logs ou incidentes sem vínculo direto com uma ME.</p>
    </div>}
  </Card>;
}
