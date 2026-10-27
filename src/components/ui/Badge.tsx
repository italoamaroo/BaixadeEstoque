import clsx from 'clsx';
import type { ReactNode } from 'react';
import { STATUS_LABELS, STATUS_STYLES } from '@/lib/constants';
import type { MovementStatus } from '@/types/db';

export function Badge({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span className={clsx('inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ring-inset', className)}>
      {children}
    </span>
  );
}

export function StatusBadge({ status }: { status: MovementStatus }) {
  return <Badge className={STATUS_STYLES[status]}>{STATUS_LABELS[status]}</Badge>;
}

export function ActiveBadge({ active }: { active: boolean }) {
  return active ? (
    <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-200">Ativo</Badge>
  ) : (
    <Badge className="bg-slate-100 text-slate-600 ring-slate-300">Inativo</Badge>
  );
}
