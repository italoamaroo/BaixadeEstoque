import { supabase, SIGNATURE_BUCKET } from './supabase';
import { searchMovements } from './api';
import { toAppError } from './errors';
import { STATUS_LABELS } from './constants';
import { fmtDateTime, fmtQty } from './format';
import type { MovementFilters } from './filters';
import type { MovementItem, MovementRow, SignatureRecord } from '@/types/db';

export const PDF_LIMIT = 500;

export interface PdfMovement {
  movement: MovementRow;
  items: MovementItem[];
  signature: SignatureRecord | null;
  signatureDataUrl: string | null;
}

export type Progress = (msg: string) => void;

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

async function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result));
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

/** Busca MEs (mesmos filtros da tela), itens e assinatura atual de cada uma. */
export async function fetchPdfData(filters: Partial<MovementFilters>, onProgress: Progress = () => undefined) {
  const movements: MovementRow[] = [];
  let total = 0;
  for (let page = 1; movements.length < PDF_LIMIT; page++) {
    onProgress(`Buscando MEs (${movements.length})…`);
    const r = await searchMovements(filters, page, 200, 'movement_at', 'asc');
    total = r.total;
    movements.push(...r.rows);
    if (r.rows.length < 200) break;
  }
  const list = movements.slice(0, PDF_LIMIT);
  const ids = list.map((m) => m.id);

  const items = new Map<string, MovementItem[]>();
  const sigs = new Map<string, SignatureRecord>();
  for (const part of chunk(ids, 100)) {
    onProgress(`Buscando itens e assinaturas (${items.size}/${ids.length})…`);
    const [it, sg] = await Promise.all([
      supabase.from('stock_movement_items').select('*').in('movement_id', part).order('line_number'),
      supabase.from('signatures').select('*').in('movement_id', part).eq('is_current', true),
    ]);
    if (it.error) throw toAppError(it.error);
    if (sg.error) throw toAppError(sg.error);
    for (const row of (it.data ?? []) as MovementItem[]) {
      const l = items.get(row.movement_id) ?? [];
      l.push(row);
      items.set(row.movement_id, l);
    }
    for (const row of (sg.data ?? []) as SignatureRecord[]) sigs.set(row.movement_id, row);
  }

  // Imagens das assinaturas (bucket privado → URLs assinadas de curta duração)
  const images = new Map<string, string>();
  const withSig = [...sigs.values()];
  let done = 0;
  for (const part of chunk(withSig, 50)) {
    const { data, error } = await supabase.storage.from(SIGNATURE_BUCKET).createSignedUrls(
      part.map((s) => s.storage_path),
      600,
    );
    if (error) throw toAppError(error);
    const urls = new Map((data ?? []).filter((d) => d.signedUrl).map((d) => [d.path, d.signedUrl as string]));
    for (const group of chunk(part, 6)) {
      await Promise.all(
        group.map(async (s) => {
          const url = urls.get(s.storage_path);
          if (!url) return;
          try {
            const res = await fetch(url);
            if (res.ok) images.set(s.movement_id, await blobToDataUrl(await res.blob()));
          } catch {
            /* assinatura indisponível: o PDF indica a ausência */
          }
        }),
      );
      done += group.length;
      onProgress(`Carregando assinaturas (${done}/${withSig.length})…`);
    }
  }

  const rows: PdfMovement[] = list.map((m) => ({
    movement: m,
    items: items.get(m.id) ?? [],
    signature: sigs.get(m.id) ?? null,
    signatureDataUrl: images.get(m.id) ?? null,
  }));
  return { rows, total, truncated: total > list.length };
}

const BRAND: [number, number, number] = [29, 67, 196];

/** A fonte padrão do PDF não tem alguns símbolos (ex.: m³); troca por equivalentes legíveis. */
function clean<T>(v: T): T {
  if (typeof v !== 'string') return v;
  return v.replace(/²/g, '2').replace(/³/g, '3').replace(/[\u2018\u2019]/g, "'").replace(/[\u201C\u201D]/g, '"') as T;
}
function cleanRows(rows: unknown[][]): never[] {
  return rows.map((r) => r.map((c) => (typeof c === 'object' && c !== null && 'content' in c ? { ...(c as object), content: clean((c as { content: string }).content) } : clean(c)))) as never[];
}

/** Gera o PDF: uma seção por ME com cabeçalho, itens e assinatura de quem recebeu. */
export async function buildMovementsPdf(
  data: PdfMovement[],
  opts: { filterLines: string[]; generatedBy: string; companyName: string; total: number; truncated: boolean },
): Promise<Blob> {
  const { jsPDF } = await import('jspdf');
  const { autoTable } = await import('jspdf-autotable');
  const doc = new jsPDF({ unit: 'mm', format: 'a4', orientation: 'portrait' });
  const W = doc.internal.pageSize.getWidth();
  const H = doc.internal.pageSize.getHeight();
  const M = 12;
  const lastY = () => (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;

  // ---------- Capa / resumo ----------
  doc.setFillColor(...BRAND);
  doc.rect(0, 0, W, 28, 'F');
  doc.setTextColor(255, 255, 255);
  doc.setFont('helvetica', 'bold');
  doc.setFontSize(15);
  doc.text('Relatório de Movimentações de Estoque', M, 13);
  doc.setFont('helvetica', 'normal');
  doc.setFontSize(10);
  doc.text(`${opts.companyName} · MEs com itens e assinatura de recebimento`, M, 21);
  doc.setTextColor(30, 41, 59);

  let y = 38;
  doc.setFontSize(10);
  const info = [
    `Gerado em: ${fmtDateTime(new Date())}`,
    `Gerado por: ${opts.generatedBy}`,
    `MEs no relatório: ${data.length}${opts.truncated ? ` (de ${opts.total} encontradas; limite de ${PDF_LIMIT} por arquivo — refine os filtros)` : ''}`,
    ...opts.filterLines,
  ];
  for (const line of info) {
    doc.text(doc.splitTextToSize(line, W - 2 * M), M, y);
    y += 6;
  }

  autoTable(doc, {
    startY: y + 2,
    head: [['Nº da ME', 'Data', 'Estoque', 'Requisitante', 'Itens', 'SA', 'Status']],
    body: cleanRows(data.map(({ movement: m }) => [
      m.me_number,
      fmtDateTime(m.movement_at),
      m.warehouse_name,
      m.requester_name,
      String(m.item_count),
      m.sa_number ?? '—',
      STATUS_LABELS[m.status],
    ])),
    styles: { fontSize: 8, cellPadding: 1.5 },
    headStyles: { fillColor: BRAND },
    margin: { left: M, right: M },
  });

  // ---------- Uma seção por ME ----------
  for (const { movement: m, items, signature, signatureDataUrl } of data) {
    doc.addPage();
    y = M;

    doc.setFillColor(...BRAND);
    doc.rect(M, y, W - 2 * M, 11, 'F');
    doc.setTextColor(255, 255, 255);
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(12);
    doc.text(m.me_number, M + 3, y + 7.3);
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9);
    doc.text(`${m.warehouse_name} · ${fmtDateTime(m.movement_at)} · ${STATUS_LABELS[m.status]}`, W - M - 3, y + 7.3, { align: 'right' });
    doc.setTextColor(30, 41, 59);
    y += 14;

    autoTable(doc, {
      startY: y,
      theme: 'plain',
      styles: { fontSize: 8.5, cellPadding: 1.2, valign: 'top' },
      columnStyles: { 0: { fontStyle: 'bold', cellWidth: 30 }, 2: { fontStyle: 'bold', cellWidth: 30 } },
      body: cleanRows([
        ['Contrato', `${m.contract_code} – ${m.contract_name}`, 'Setor', m.sector_name],
        ['Frente/Equip.', m.service_front_name ?? '—', 'Ordem de serviço', m.service_order ?? '—'],
        ['Ativo fixo', m.fixed_asset ?? '—', 'Local de aplicação', m.application_location ?? '—'],
        ['Requisitante', `${m.requester_name} (${m.requester_registration})`, 'Almoxarife', m.storekeeper_name ?? '—'],
        ['Número da SA', m.sa_number ?? 'Pendente', 'SA informada em', m.sa_informed_at ? fmtDateTime(m.sa_informed_at) : '—'],
        ...(m.notes ? [['Observações', { content: m.notes, colSpan: 3 }]] : []),
      ]),
      margin: { left: M, right: M },
    });

    autoTable(doc, {
      startY: lastY() + 3,
      head: [['Item', 'Código', 'Referência', 'Material', 'Un.', 'Qtd. sol.', 'Qtd. atd.', 'Localiz.', 'Conta']],
      body: cleanRows(items.map((i) => [
        String(i.line_number),
        i.material_code,
        i.material_reference ?? '',
        i.notes ? `${i.material_name}\nObs.: ${i.notes}` : i.material_name,
        i.unit,
        fmtQty(i.quantity_requested),
        fmtQty(i.quantity_delivered),
        i.location ?? '',
        i.account_code ?? '',
      ])),
      styles: { fontSize: 8, cellPadding: 1.4 },
      headStyles: { fillColor: [241, 245, 249], textColor: [30, 41, 59], fontStyle: 'bold' },
      columnStyles: { 0: { halign: 'center', cellWidth: 10 }, 5: { halign: 'right' }, 6: { halign: 'right', fontStyle: 'bold' } },
      margin: { left: M, right: M },
    });

    // Assinatura
    y = lastY() + 5;
    if (y + 42 > H - 14) {
      doc.addPage();
      y = M;
    }
    doc.setDrawColor(148, 163, 184);
    doc.rect(M, y, W - 2 * M, 38);
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(9);
    doc.text('RECEBIDO POR / ASSINATURA', M + 3, y + 5);
    doc.setFont('helvetica', 'normal');

    if (signatureDataUrl) {
      try {
        const props = doc.getImageProperties(signatureDataUrl);
        const maxW = 80;
        const maxH = 22;
        const ratio = Math.min(maxW / props.width, maxH / props.height);
        const w = props.width * ratio;
        const h = props.height * ratio;
        doc.addImage(signatureDataUrl, props.fileType || 'PNG', M + 3, y + 7 + (maxH - h) / 2, w, h);
      } catch {
        doc.text('[assinatura não pôde ser exibida]', M + 3, y + 18);
      }
    } else {
      doc.setTextColor(185, 28, 28);
      doc.text(signature ? '[imagem da assinatura indisponível]' : '[sem assinatura registrada]', M + 3, y + 18);
      doc.setTextColor(30, 41, 59);
    }
    doc.line(M + 3, y + 31, M + 90, y + 31);
    doc.setFontSize(8.5);
    const signer = signature
      ? `${signature.signer_name} (${signature.signer_registration}) · assinado em ${fmtDateTime(signature.signed_at)}`
      : `${m.received_by_name ?? m.requester_name}`;
    doc.text(clean(signer), M + 3, y + 35);
    doc.setFontSize(7.5);
    doc.setTextColor(100, 116, 139);
    doc.text(
      doc.splitTextToSize(`Documento gerado eletronicamente. Identificador da ME: ${m.id}`, 85),
      W - M - 3,
      y + 30,
      { align: 'right' },
    );
    doc.setTextColor(30, 41, 59);

    if (m.status === 'cancelada') {
      doc.setTextColor(185, 28, 28);
      doc.setFont('helvetica', 'bold');
      doc.setFontSize(9);
      doc.text(
        doc.splitTextToSize(`ME CANCELADA em ${fmtDateTime(m.cancelled_at)} por ${m.cancelled_by_name ?? '—'}: ${m.cancel_reason ?? ''}`, W - 2 * M),
        M,
        y + 44,
      );
      doc.setTextColor(30, 41, 59);
      doc.setFont('helvetica', 'normal');
    }
  }

  // Rodapé com paginação
  const pages = doc.getNumberOfPages();
  for (let p = 1; p <= pages; p++) {
    doc.setPage(p);
    doc.setFontSize(7.5);
    doc.setTextColor(100, 116, 139);
    doc.text(`${opts.companyName} · Baixas de Estoque`, M, H - 6);
    doc.text(`Página ${p} de ${pages}`, W - M, H - 6, { align: 'right' });
  }

  return doc.output('blob');
}
