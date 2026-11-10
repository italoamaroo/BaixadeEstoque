import type { ReactNode } from 'react';
import { PackageMinus } from 'lucide-react';

export function AuthLayout({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col bg-gradient-to-b from-brand-900 to-brand-800 px-4 py-10 sm:justify-center">
      <div className="mx-auto w-full max-w-sm">
        <div className="mb-6 flex items-center gap-3 text-white">
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-white/15">
            <PackageMinus className="h-6 w-6" />
          </div>
          <div>
            <p className="text-lg font-bold leading-tight">Baixas de Estoque</p>
            <p className="text-sm text-brand-200">Muribeca · Dois Irmãos</p>
          </div>
        </div>
        <div className="rounded-2xl bg-white p-6 shadow-xl">
          <h1 className="text-xl font-bold text-slate-900">{title}</h1>
          {subtitle && <p className="mt-1 text-sm text-slate-500">{subtitle}</p>}
          <div className="mt-6">{children}</div>
        </div>
      </div>
    </div>
  );
}
