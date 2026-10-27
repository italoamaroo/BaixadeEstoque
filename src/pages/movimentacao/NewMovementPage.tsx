import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { toast } from 'sonner';
import { Check, RotateCcw } from 'lucide-react';
import clsx from 'clsx';
import { useAuth } from '@/contexts/AuthContext';
import { useWarehouse } from '@/contexts/WarehouseContext';
import { clearDraft, emptyDraft, loadDraft, saveDraft, takeDuplicate, type MovementDraft } from '@/lib/draft';
import type { CartRules } from '@/lib/cart';
import type { CartItem } from '@/types/db';
import { PageHeader } from '@/components/ui/Card';
import { Button } from '@/components/ui/Button';
import { StepWarehouse } from './StepWarehouse';
import { StepItems } from './StepItems';
import { StepDetails } from './StepDetails';
import { StepRequester } from './StepRequester';
import { StepSignature } from './StepSignature';
import { StepReview } from './StepReview';
import { StepSuccess } from './StepSuccess';

export const STEPS = ['Estoque', 'Materiais', 'Dados', 'Requisitante', 'Assinatura', 'Revisão'] as const;

export interface StepProps {
  draft: MovementDraft;
  update: (patch: Partial<MovementDraft>) => void;
  setCart: (cart: CartItem[]) => void;
  goTo: (step: number) => void;
  next: () => void;
  back: () => void;
  rules: CartRules;
}

export interface CreatedInfo {
  id: string;
  me_number: string;
  status: string;
  warehouse_name: string;
}

export function NewMovementPage() {
  const { userId, settings } = useAuth();
  const { current, options } = useWarehouse();
  const [draft, setDraft] = useState<MovementDraft | null>(null);
  const [created, setCreated] = useState<CreatedInfo | null>(null);
  const topRef = useRef<HTMLDivElement>(null);

  const rules: CartRules = useMemo(
    () => ({
      allowDeliveredAboveRequested: Boolean(settings?.allow_delivered_above_requested),
      allowDuplicateLines: Boolean(settings?.allow_duplicate_material_lines),
    }),
    [settings],
  );

  // Carrega rascunho existente, duplicação ou inicia nova saída
  useEffect(() => {
    if (!userId || draft) return;
    const dup = takeDuplicate();
    if (dup) {
      setDraft(dup);
      toast.info('Nova saída criada a partir de uma ME existente. Revise os materiais e colha uma nova assinatura.');
      return;
    }
    const saved = loadDraft(userId);
    if (saved && (saved.cart.length > 0 || saved.step > 1)) {
      setDraft(saved);
      toast.info('Recuperamos a saída que estava em andamento.');
      return;
    }
    const whId = current?.id ?? (options.length === 1 ? options[0].id : '');
    setDraft(emptyDraft(whId));
  }, [userId, current, options, draft]);

  useEffect(() => {
    if (userId && draft && !created) saveDraft(userId, draft);
  }, [userId, draft, created]);

  const update = useCallback((patch: Partial<MovementDraft>) => setDraft((d) => (d ? { ...d, ...patch } : d)), []);

  const setCart = useCallback(
    (cart: CartItem[]) =>
      setDraft((d) => {
        if (!d) return d;
        if (d.signature_data_url) {
          toast.warning('Os materiais mudaram depois da assinatura. Será necessário assinar novamente.');
          return { ...d, cart, signature_data_url: null, signature_signed_at: null, signature_path: null };
        }
        return { ...d, cart };
      }),
    [],
  );

  const goTo = useCallback(
    (step: number) => {
      update({ step });
      requestAnimationFrame(() => topRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
    },
    [update],
  );

  const restart = () => {
    if (!userId) return;
    if (draft && draft.cart.length > 0 && !window.confirm('Descartar a saída em andamento? Os materiais adicionados serão perdidos.')) return;
    clearDraft(userId);
    setCreated(null);
    setDraft(emptyDraft(current?.id ?? ''));
  };

  if (!draft) return null;

  if (created) {
    return (
      <StepSuccess
        created={created}
        onNew={() => {
          setCreated(null);
          setDraft(emptyDraft(current?.id ?? ''));
        }}
      />
    );
  }

  const props: StepProps = {
    draft,
    update,
    setCart,
    goTo,
    next: () => goTo(Math.min(draft.step + 1, STEPS.length - 1)),
    back: () => goTo(Math.max(draft.step - 1, 0)),
    rules,
  };

  return (
    <div ref={topRef} className="mx-auto max-w-3xl scroll-mt-20">
      <PageHeader
        title="Nova saída de material"
        subtitle={`Identificador temporário: ${draft.id.slice(0, 8).toUpperCase()}`}
        actions={
          (draft.cart.length > 0 || draft.step > 0) && (
            <Button variant="ghost" size="sm" icon={<RotateCcw className="h-4 w-4" />} onClick={restart}>
              Recomeçar
            </Button>
          )
        }
      />

      <ol className="mb-5 flex items-center gap-1 overflow-x-auto pb-1" aria-label="Etapas">
        {STEPS.map((label, idx) => {
          const done = idx < draft.step;
          const active = idx === draft.step;
          return (
            <li key={label} className="flex min-w-0 flex-1 items-center gap-1">
              <button
                type="button"
                disabled={!done}
                onClick={() => done && goTo(idx)}
                className={clsx(
                  'flex min-w-0 flex-1 flex-col items-center gap-1 rounded-lg px-1 py-1 text-[11px] font-medium sm:text-xs',
                  active ? 'text-brand-800' : done ? 'text-slate-700 hover:bg-slate-100' : 'text-slate-400',
                )}
                aria-current={active ? 'step' : undefined}
              >
                <span
                  className={clsx(
                    'flex h-7 w-7 items-center justify-center rounded-full text-xs font-bold',
                    active ? 'bg-brand-700 text-white' : done ? 'bg-emerald-600 text-white' : 'bg-slate-200 text-slate-500',
                  )}
                >
                  {done ? <Check className="h-4 w-4" /> : idx + 1}
                </span>
                <span className={clsx('truncate', !active && 'hidden sm:block')}>{label}</span>
              </button>
            </li>
          );
        })}
      </ol>

      {draft.step === 0 && <StepWarehouse {...props} />}
      {draft.step === 1 && <StepItems {...props} />}
      {draft.step === 2 && <StepDetails {...props} />}
      {draft.step === 3 && <StepRequester {...props} />}
      {draft.step === 4 && <StepSignature {...props} />}
      {draft.step === 5 && (
        <StepReview
          {...props}
          onCreated={(info) => {
            if (userId) clearDraft(userId);
            setCreated(info);
          }}
        />
      )}
    </div>
  );
}
