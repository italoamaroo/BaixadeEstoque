import { STATUS_LABELS } from './constants';
import type { MovementStatus } from '@/types/db';

export type ExportKind = 'resumo' | 'itens';

interface ColumnDef {
  header: string;
  key: string;
  width: number;
  type?: 'date' | 'time' | 'datetime' | 'number' | 'int' | 'text';
}

export const SUMMARY_COLUMNS: ColumnDef[] = [
  { header: 'Número da ME', key: 'me_number', width: 22 },
  { header: 'Data', key: 'date', width: 12, type: 'date' },
  { header: 'Hora', key: 'time', width: 8, type: 'time' },
  { header: 'Estoque', key: 'warehouse_name', width: 14 },
  { header: 'Contrato', key: 'contract', width: 36 },
  { header: 'Setor', key: 'sector_name', width: 24 },
  { header: 'Frente de Serviço/Equipamento', key: 'service_front_name', width: 32 },
  { header: 'Ordem de Serviço', key: 'service_order', width: 18 },
  { header: 'Ativo Fixo', key: 'fixed_asset', width: 16 },
  { header: 'Local de Aplicação', key: 'application_location', width: 24 },
  { header: 'Requisitante', key: 'requester_name', width: 28 },
  { header: 'Matrícula', key: 'requester_registration', width: 12 },
  { header: 'Quantidade de Itens', key: 'item_count', width: 12, type: 'int' },
  { header: 'Número da SA', key: 'sa_number', width: 16 },
  { header: 'Status', key: 'status_label', width: 20 },
  { header: 'Responsável pela Baixa', key: 'storekeeper_name', width: 24 },
  { header: 'Data da SA', key: 'sa_informed_at', width: 17, type: 'datetime' },
  { header: 'Usuário que Informou a SA', key: 'sa_informed_by_name', width: 24 },
  { header: 'Motivo do Cancelamento', key: 'cancel_reason', width: 30 },
  { header: 'Observações', key: 'notes', width: 36 },
];

export const ITEM_COLUMNS: ColumnDef[] = [
  { header: 'Número da ME', key: 'me_number', width: 22 },
  { header: 'Data', key: 'date', width: 12, type: 'date' },
  { header: 'Hora', key: 'time', width: 8, type: 'time' },
  { header: 'Estoque', key: 'warehouse_name', width: 14 },
  { header: 'Item', key: 'line_number', width: 6, type: 'int' },
  { header: 'Código', key: 'material_code', width: 14 },
  { header: 'Referência', key: 'material_reference', width: 18 },
  { header: 'Nome do Material', key: 'material_name', width: 34 },
  { header: 'Unidade', key: 'unit', width: 8 },
  { header: 'Quantidade Solicitada', key: 'quantity_requested', width: 12, type: 'number' },
  { header: 'Quantidade Atendida', key: 'quantity_delivered', width: 12, type: 'number' },
  { header: 'Localização', key: 'location', width: 12 },
  { header: 'Conta', key: 'account', width: 28 },
  { header: 'Contrato', key: 'contract', width: 36 },
  { header: 'Setor', key: 'sector_name', width: 24 },
  { header: 'Frente de Serviço/Equipamento', key: 'service_front_name', width: 32 },
  { header: 'Ordem de Serviço', key: 'service_order', width: 18 },
  { header: 'Ativo Fixo', key: 'fixed_asset', width: 16 },
  { header: 'Local de Aplicação', key: 'application_location', width: 24 },
  { header: 'Requisitante', key: 'requester_name', width: 28 },
  { header: 'Número da SA', key: 'sa_number', width: 16 },
  { header: 'Status', key: 'status_label', width: 20 },
  { header: 'Responsável pela Baixa', key: 'storekeeper_name', width: 24 },
  { header: 'Observação do Item', key: 'item_notes', width: 30 },
];

/**
 * O Excel não guarda fuso horário. Convertemos para "horário de parede" local,
 * para a planilha mostrar a mesma data/hora que a tela.
 */
export function toExcelLocalDate(iso: string | null | undefined): Date | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()));
}

/** Prepara as linhas vindas do RPC export_movements para as colunas do Excel. */
export function mapExportRows(rows: Record<string, unknown>[]): Record<string, unknown>[] {
  return rows.map((r) => {
    const at = toExcelLocalDate(r.movement_at as string);
    return {
      ...r,
      date: at,
      time: at,
      sa_informed_at: toExcelLocalDate(r.sa_informed_at as string | null),
      status_label: STATUS_LABELS[r.status as MovementStatus] ?? r.status,
      quantity_requested: r.quantity_requested !== undefined ? Number(r.quantity_requested) : undefined,
      quantity_delivered: r.quantity_delivered !== undefined ? Number(r.quantity_delivered) : undefined,
      item_count: r.item_count !== undefined ? Number(r.item_count) : undefined,
    };
  });
}

export async function buildWorkbook(
  kind: ExportKind,
  rows: Record<string, unknown>[],
  filterLines: string[],
  generatedBy: string,
): Promise<Blob> {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Baixas de Estoque';
  wb.created = new Date();

  const columns = kind === 'itens' ? ITEM_COLUMNS : SUMMARY_COLUMNS;
  const ws = wb.addWorksheet(kind === 'itens' ? 'Detalhamento por item' : 'Resumo por ME', {
    views: [{ state: 'frozen', ySplit: 1 }],
  });

  ws.columns = columns.map((c) => ({ header: c.header, key: c.key, width: c.width }));
  for (const row of mapExportRows(rows)) ws.addRow(row);

  const header = ws.getRow(1);
  header.height = 30;
  header.eachCell((cell) => {
    cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1D43C4' } };
    cell.alignment = { vertical: 'middle', horizontal: 'center', wrapText: true };
    cell.border = { bottom: { style: 'thin', color: { argb: 'FF162250' } } };
  });

  columns.forEach((c, idx) => {
    const col = ws.getColumn(idx + 1);
    if (c.type === 'date') col.numFmt = 'dd/mm/yyyy';
    if (c.type === 'time') col.numFmt = 'hh:mm';
    if (c.type === 'datetime') col.numFmt = 'dd/mm/yyyy hh:mm';
    if (c.type === 'number') col.numFmt = '#,##0.###';
    if (c.type === 'int') col.numFmt = '0';
    if (c.type && c.type !== 'text') col.alignment = { horizontal: c.type === 'number' || c.type === 'int' ? 'right' : 'center' };
  });

  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: Math.max(1, ws.rowCount), column: columns.length } };

  // Ajuste de largura pelo conteúdo (limitado)
  columns.forEach((c, idx) => {
    if (c.type && c.type !== 'text') return;
    let max = c.header.length;
    ws.getColumn(idx + 1).eachCell({ includeEmpty: false }, (cell) => {
      const len = String(cell.value ?? '').length;
      if (len > max) max = len;
    });
    ws.getColumn(idx + 1).width = Math.min(Math.max(c.width, max + 2), 60);
  });

  const info = wb.addWorksheet('Filtros');
  info.columns = [{ width: 28 }, { width: 70 }];
  info.addRow(['Relatório', kind === 'itens' ? 'Detalhamento por item' : 'Resumo por ME']);
  info.addRow(['Gerado em', new Date().toLocaleString('pt-BR')]);
  info.addRow(['Gerado por', generatedBy]);
  info.addRow(['Registros', rows.length]);
  info.addRow([]);
  info.addRow(['Filtros aplicados']);
  for (const line of filterLines) info.addRow(['', line]);
  info.getColumn(1).font = { bold: true };

  const buffer = await wb.xlsx.writeBuffer();
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

export function downloadBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
