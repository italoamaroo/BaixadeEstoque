import { useState } from 'react';
import { toast } from 'sonner';
import { ArrowLeft, ArrowRight, QrCode, Search } from 'lucide-react';
import clsx from 'clsx';
import { QRScanner } from '@/components/QRScanner';
import { MaterialSearch } from '@/components/MaterialSearch';
import { Button } from '@/components/ui/Button';
import { Alert, Card } from '@/components/ui/Card';
import { findMaterialByCode, logEvent } from '@/lib/api';
import { addToCart, findDuplicate, validateCart } from '@/lib/cart';
import { errorMessage } from '@/lib/errors';
import { NOT_FOUND_MATERIAL_MESSAGE } from '@/lib/constants';
import { useWarehouse } from '@/contexts/WarehouseContext';
import type { Material } from '@/types/db';
import type { StepProps } from './NewMovementPage';
import { AddItemModal, type PendingMaterial } from './AddItemModal';
import { CartList } from './CartList';

export function StepItems({ draft, setCart, next, back, rules }: StepProps) {
  const { options } = useWarehouse();
  const [tab, setTab] = useState<'qr' | 'busca'>('qr');
  const [pending, setPending] = useState<PendingMaterial | null>(null);
  const [lookupBusy, setLookupBusy] = useState(false);
  const [scanMessage, setScanMessage] = useState<{ tone: 'error' | 'warning'; text: string } | null>(null);
  const warehouse = options.find((w) => w.id === draft.warehouse_id);

  const handleScan = async (code: string) => {
    if (lookupBusy || pending) return;
    setLookupBusy(true);
    setScanMessage(null);
    try {
      const r = await findMaterialByCode(code);
      if (!r.found || !r.material) {
        const text = r.reason === 'invalido' ? 'QR Code inválido: o conteúdo lido não é um código de material deste sistema.' : NOT_FOUND_MATERIAL_MESSAGE;
        setScanMessage({ tone: 'error', text });
        toast.error(text);
        void logEvent('qr.leitura_nao_encontrada', null, { codigo: code.slice(0, 80), motivo: r.reason ?? 'nao_cadastrado' });
        return;
      }
      if (!r.material.active) {
        setScanMessage({ tone: 'warning', text: `Produto inativo: ${r.material.name} (${r.material.code}). Ele não pode ser baixado.` });
      }
      setPending({ material: r.material, entry_method: 'qr_code', scanned_code: code });
    } catch (err) {
      const text = errorMessage(err);
      setScanMessage({ tone: 'error', text });
      toast.error(text);
    } finally {
      setLookupBusy(false);
    }
  };

  const handleSelect = (m: Material) => setPending({ material: m, entry_method: 'pesquisa_manual', scanned_code: null });

  const confirmAdd = (req: number, del: number, notes: string, mode: 'somar' | 'separar') => {
    if (!pending) return;
    try {
      const nextCart = addToCart(
        draft.cart,
        { material: pending.material, quantity_requested: req, quantity_delivered: del, entry_method: pending.entry_method, scanned_code: pending.scanned_code, notes },
        mode,
        rules,
      );
      setCart(nextCart);
      toast.success(`${pending.material.name} adicionado à ME.`);
      setPending(null);
      setScanMessage(null);
    } catch (err) {
      toast.error((err as Error).message);
    }
  };

  const proceed = () => {
    const problems = validateCart(draft.cart, rules);
    if (problems.length) {
      toast.error(problems[0]);
      return;
    }
    next();
  };

  return (
    <div className="space-y-4">
      <Card>
        <div className="mb-4 flex items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-slate-900">Materiais</h2>
            <p className="text-sm text-slate-500">
              Estoque de origem: <strong className="text-slate-700">{warehouse?.name ?? '—'}</strong>
            </p>
          </div>
        </div>
        <div className="mb-4 grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'qr'}
            onClick={() => setTab('qr')}
            className={clsx('flex items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-semibold', tab === 'qr' ? 'bg-white text-brand-800 shadow' : 'text-slate-600')}
          >
            <QrCode className="h-5 w-5" /> Ler QR Code
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'busca'}
            onClick={() => setTab('busca')}
            className={clsx('flex items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-semibold', tab === 'busca' ? 'bg-white text-brand-800 shadow' : 'text-slate-600')}
          >
            <Search className="h-5 w-5" /> Pesquisar
          </button>
        </div>

        {tab === 'qr' ? (
          <div className="mx-auto max-w-md space-y-3">
            <QRScanner onScan={(c) => void handleScan(c)} paused={Boolean(pending) || lookupBusy} />
            {lookupBusy && <p className="text-center text-sm text-slate-500">Consultando material…</p>}
            {scanMessage && (
              <Alert tone={scanMessage.tone}>
                {scanMessage.text}
                {scanMessage.tone === 'error' && (
                  <button type="button" className="ml-1 font-semibold underline" onClick={() => setTab('busca')}>
                    Pesquisar manualmente
                  </button>
                )}
              </Alert>
            )}
          </div>
        ) : (
          <MaterialSearch onSelect={handleSelect} autoFocus />
        )}
      </Card>

      <Card>
        <h3 className="mb-3 font-semibold text-slate-900">Itens da ME</h3>
        <CartList cart={draft.cart} setCart={setCart} rules={rules} />
      </Card>

      <div className="sticky bottom-20 z-10 flex gap-3 lg:bottom-4">
        <Button variant="secondary" size="lg" icon={<ArrowLeft className="h-5 w-5" />} onClick={back}>
          Voltar
        </Button>
        <Button size="lg" block icon={<ArrowRight className="h-5 w-5" />} onClick={proceed} disabled={draft.cart.length === 0}>
          Continuar ({draft.cart.length} {draft.cart.length === 1 ? 'item' : 'itens'})
        </Button>
      </div>

      <AddItemModal
        pending={pending}
        existing={pending ? findDuplicate(draft.cart, pending.material.id) : undefined}
        rules={rules}
        onCancel={() => setPending(null)}
        onConfirm={confirmAdd}
      />
    </div>
  );
}
