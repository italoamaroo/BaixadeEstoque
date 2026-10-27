import type { MovementDetail } from '@/lib/api';
import { fmtDate, fmtDateTime, fmtQty } from '@/lib/format';
import { STATUS_LABELS } from '@/lib/constants';

interface Props {
  detail: MovementDetail;
  signatureUrl: string | null;
  companyName: string;
}

/**
 * Comprovante para impressão / "Salvar como PDF" do navegador.
 * Segue a estrutura do formulário em papel "MOVIMENTAÇÃO DE ESTOQUE".
 */
export function MovementPrint({ detail, signatureUrl, companyName }: Props) {
  const { movement: m, items } = detail;
  const minRows = Math.max(0, 8 - items.length);
  const cell = 'border border-slate-800 px-1.5 py-1 align-top';
  const label = 'block text-[9px] font-semibold uppercase leading-tight text-slate-700';

  return (
    <div className="print-sheet mx-auto max-w-[190mm] bg-white text-[11px] text-black">
      <table className="w-full border-collapse">
        <tbody>
          <tr>
            <td className={`${cell} w-[28%]`}>
              <span className="text-sm font-bold">{companyName}</span>
              <span className="block text-[10px]">Almoxarifado {m.warehouse_name}</span>
            </td>
            <td className={`${cell} text-center`}>
              <span className="text-lg font-bold tracking-wide">MOVIMENTAÇÃO DE ESTOQUE</span>
            </td>
            <td className={`${cell} w-[16%]`}>
              <span className={label}>Tipo</span>
              <span>[{m.movement_type === 'saida' ? 'X' : ' '}] SAÍDA&nbsp; [{m.movement_type === 'entrada' ? 'X' : ' '}] ENTRADA</span>
            </td>
            <td className={`${cell} w-[22%]`}>
              <span className={label}>ME Nº</span>
              <span className="font-mono text-[12px] font-bold">{m.me_number}</span>
              <span className={`${label} mt-1`}>Data</span>
              <span>{fmtDateTime(m.movement_at)}</span>
            </td>
          </tr>
        </tbody>
      </table>

      <table className="mt-[-1px] w-full border-collapse">
        <tbody>
          <tr>
            <td className={`${cell} w-1/3`}>
              <span className={label}>Contrato</span>
              {m.contract_code} – {m.contract_name}
            </td>
            <td className={`${cell} w-1/3`}>
              <span className={label}>Setor</span>
              {m.sector_name}
            </td>
            <td className={cell}>
              <span className={label}>Frente de serviço / Equipamento</span>
              {m.service_front_name ?? ''}
            </td>
          </tr>
          <tr>
            <td className={cell}>
              <span className={label}>Ordem de serviço</span>
              {m.service_order ?? ''}
            </td>
            <td className={cell}>
              <span className={label}>Ativo fixo (AF)</span>
              {m.fixed_asset ?? ''}
            </td>
            <td className={cell}>
              <span className={label}>Local aplicação</span>
              {m.application_location ?? ''}
            </td>
          </tr>
        </tbody>
      </table>

      <table className="mt-[-1px] w-full border-collapse">
        <thead>
          <tr className="bg-slate-100">
            {['Item', 'Referência', 'Nome do material', 'Unid.', 'Qtd. sol.', 'Qtd. atd.', 'Localiz.', 'Conta'].map((h) => (
              <th key={h} className={`${cell} text-center text-[9px] font-semibold uppercase`}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {items.map((i) => (
            <tr key={i.id}>
              <td className={`${cell} text-center`}>{i.line_number}</td>
              <td className={cell}>
                {i.material_reference ?? ''}
                <span className="block text-[9px] text-slate-600">{i.material_code}</span>
              </td>
              <td className={cell}>
                {i.material_name}
                {i.notes && <span className="block text-[9px] italic">Obs.: {i.notes}</span>}
              </td>
              <td className={`${cell} text-center`}>{i.unit}</td>
              <td className={`${cell} text-right`}>{fmtQty(i.quantity_requested)}</td>
              <td className={`${cell} text-right font-semibold`}>{fmtQty(i.quantity_delivered)}</td>
              <td className={`${cell} text-center`}>{i.location ?? ''}</td>
              <td className={cell}>{i.account_code ?? ''}</td>
            </tr>
          ))}
          {Array.from({ length: minRows }).map((_, idx) => (
            <tr key={`empty-${idx}`}>
              {Array.from({ length: 8 }).map((__, c) => (
                <td key={c} className={`${cell} h-5`} />
              ))}
            </tr>
          ))}
        </tbody>
      </table>

      <table className="mt-[-1px] w-full border-collapse">
        <tbody>
          <tr>
            <td className={`${cell} w-1/3`}>
              <span className={label}>Requisitante / data</span>
              {m.requester_name} ({m.requester_registration})
              <span className="block">{fmtDateTime(m.requested_at)}</span>
            </td>
            <td className={`${cell} w-1/3`}>
              <span className={label}>Aprovado / data</span>
              {m.approved_by_name ? (
                <>
                  {m.approved_by_name}
                  <span className="block">{fmtDateTime(m.approved_at)}</span>
                </>
              ) : (
                <>
                  Baixa: {m.storekeeper_name}
                  <span className="block">{fmtDateTime(m.created_at)}</span>
                </>
              )}
            </td>
            <td className={cell}>
              <span className={label}>Recebido / data</span>
              {signatureUrl ? <img src={signatureUrl} alt="Assinatura" className="h-14 max-w-full object-contain" /> : <span className="block h-14" />}
              <span className="block border-t border-slate-500 pt-0.5">
                {m.received_by_name} ({m.received_by_registration}) · {fmtDateTime(m.received_at)}
              </span>
            </td>
          </tr>
        </tbody>
      </table>

      <div className="mt-2 flex flex-wrap justify-between gap-2 text-[10px] text-slate-700">
        <span>Status: {STATUS_LABELS[m.status]}</span>
        <span>SA: {m.sa_number ?? 'pendente'}</span>
        {m.notes && <span className="w-full">Observações: {m.notes}</span>}
        {m.status === 'cancelada' && (
          <span className="w-full font-semibold text-red-700">
            CANCELADA em {fmtDate(m.cancelled_at)} por {m.cancelled_by_name}: {m.cancel_reason}
          </span>
        )}
        <span className="w-full text-[9px] text-slate-500">
          Documento gerado eletronicamente em {fmtDateTime(new Date())}. Identificador: {m.id}
        </span>
      </div>
    </div>
  );
}
