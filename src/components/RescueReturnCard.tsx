import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from './ui/Button';
import { Card, CardHeader, Alert } from './ui/Card';
import { Textarea } from './ui/Field';
import { returnRescue } from '@/lib/api';
import { errorMessage } from '@/lib/errors';
import { fmtQty, fmtDateTime, parseQty } from '@/lib/format';
import type { MovementItem, MovementRow } from '@/types/db';

export function RescueReturnCard({ movement, items, canReturn, onSaved }: { movement: MovementRow; items: MovementItem[]; canReturn: boolean; onSaved: () => void }) {
  const [used, setUsed] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const returned = Boolean(movement.rescue_returned_at);
  const editable = canReturn && movement.status === 'aguardando_retorno' && !returned;
  const totalOut = items.reduce((n, i) => n + Number(i.rescue_quantity_out ?? i.quantity_delivered), 0);
  const totalUsed = items.reduce((n, i) => n + Number(i.quantity_delivered), 0);
  const outcome = !returned ? movement.status === 'aguardando_retorno' ? 'Aguardando retorno' : 'Aguardando confirmação da retirada' : totalUsed === 0 ? 'Sem consumo — devolução total' : totalUsed === totalOut ? 'Utilizado integralmente' : 'Utilizado em parte';
  const save = async () => {
    const rows = items.map((i) => ({ id: i.id, used: parseQty(used[i.id] ?? '') }));
    if (!confirmed || note.trim().length < 5) { setError('Confirme a conferência com o mecânico e descreva o retorno.'); return; }
    if (rows.some((r, index) => !used[r.id]?.trim() || !Number.isFinite(r.used) || r.used < 0 || r.used > Number(items[index].quantity_delivered))) { setError('Informe o utilizado em cada item, entre zero e a quantidade retirada.'); return; }
    setBusy(true); setError(null);
    try {
      await returnRescue(movement.id, rows, note.trim());
      toast.success('Retorno conferido. Somente o utilizado segue para lançamento.');
      onSaved();
    } catch (err) { setError(errorMessage(err)); } finally { setBusy(false); }
  };
  return <Card className="mb-4 border-sky-300">
    <CardHeader title={`Socorro · ${outcome}`} subtitle={returned ? `Conferido em ${fmtDateTime(movement.rescue_returned_at)}` : 'A ME só segue para lançamento após a conferência do retorno.'} />
    {error && <Alert tone="error">{error}</Alert>}
    <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="text-left"><th className="p-2">Material</th><th className="p-2">Retirado</th><th className="p-2">Utilizado</th><th className="p-2">Devolvido</th></tr></thead>
      <tbody>{items.map((i) => <tr key={i.id} className="border-t"><td className="p-2">{i.material_name} ({i.unit})</td><td className="p-2">{fmtQty(i.rescue_quantity_out ?? i.quantity_delivered)}</td><td className="p-2">{editable ? <input aria-label={`Utilizado: ${i.material_name}`} className="w-24 rounded border border-slate-300 p-2" inputMode="decimal" value={used[i.id] ?? ''} onChange={(e) => setUsed({ ...used, [i.id]: e.target.value })} /> : returned ? fmtQty(i.quantity_delivered) : 'A conferir'}</td><td className="p-2">{returned ? fmtQty(i.rescue_quantity_returned ?? 0) : editable && used[i.id]?.trim() && Number.isFinite(parseQty(used[i.id])) ? fmtQty(Number(i.quantity_delivered) - parseQty(used[i.id])) : 'A conferir'}</td></tr>)}</tbody></table></div>
    {returned && <p className="mt-3 text-sm">Conferência: {movement.rescue_return_note}</p>}
    {editable && <div className="mt-4 space-y-3">
      <Textarea label="Conferência do retorno e confirmação do mecânico" value={note} maxLength={2000} onChange={(e) => setNote(e.target.value)} />
      <label className="flex items-start gap-2 text-sm"><input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} />Conferi com o mecânico o utilizado e recebi fisicamente as quantidades indicadas como devolvidas.</label>
      <p className="text-xs text-slate-500">Se houver diferença ou material ainda não devolvido, mantenha a ME aberta. Após confirmar, as quantidades ficam preservadas para conferência.</p>
      <Button loading={busy} onClick={() => void save()}>Confirmar retorno do socorro</Button>
    </div>}
  </Card>;
}
