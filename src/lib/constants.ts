import type { AppRole, MovementStatus } from '@/types/db';

export const STATUS_LABELS: Record<MovementStatus, string> = {
  rascunho: 'Rascunho',
  aguardando_assinatura: 'Aguardando assinatura',
  aguardando_aprovacao: 'Aguardando aprovação',
  aguardando_sa: 'Aguardando SA',
  sa_informada: 'Aguardando baixa no ERP',
  concluida: 'Concluída',
  cancelada: 'Cancelada',
};

/** Classes de cor por status: azul = em andamento, laranja = pendência, verde = concluído, vermelho = cancelado. */
export const STATUS_STYLES: Record<MovementStatus, string> = {
  rascunho: 'bg-slate-100 text-slate-700 ring-slate-300',
  aguardando_assinatura: 'bg-amber-50 text-amber-800 ring-amber-300',
  aguardando_aprovacao: 'bg-amber-50 text-amber-800 ring-amber-300',
  aguardando_sa: 'bg-orange-50 text-orange-800 ring-orange-300',
  sa_informada: 'bg-brand-50 text-brand-800 ring-brand-300',
  concluida: 'bg-emerald-50 text-emerald-800 ring-emerald-300',
  cancelada: 'bg-red-50 text-red-700 ring-red-300',
};

export const STATUS_ORDER: MovementStatus[] = [
  'aguardando_aprovacao',
  'aguardando_sa',
  'sa_informada',
  'concluida',
  'cancelada',
];

export const ROLE_LABELS: Record<AppRole, string> = {
  almoxarife: 'Almoxarife',
  equipe_sa: 'Equipe de lançamento da SA',
  gestor: 'Gestor',
  admin: 'Administrador',
};

export const ROLE_DESCRIPTIONS: Record<AppRole, string> = {
  almoxarife: 'Registra saídas nos estoques autorizados (lê QR Code, monta a ME, coleta assinatura), faz a baixa no ERP com a SA informada e confirma no sistema, cancela por devolução antes da SA e cadastra materiais, QR Codes/etiquetas, funcionários e tabelas auxiliares.',
  equipe_sa: 'Consulta as MEs, acompanha pendências, informa e corrige o número da SA (com justificativa). A baixa no ERP fica com o almoxarife.',
  gestor: 'Painel gerencial, todas as consultas, assinaturas, histórico, exportação para Excel, aprovação, correção e cancelamento de MEs.',
  admin: 'Tudo do almoxarife nos cadastros, mais usuários, perfis, estoques, parâmetros e auditoria.',
};

/** Ações da interface por perfil. A mesma regra existe no banco (RLS + RPC). */
export const PERMISSIONS = {
  createMovement: ['almoxarife', 'gestor', 'admin'],
  informSa: ['equipe_sa', 'gestor', 'admin'],
  completeMovement: ['almoxarife', 'gestor', 'admin'],
  viewPending: ['equipe_sa', 'almoxarife', 'gestor', 'admin'],
  correctSaAfterCompletion: ['gestor', 'admin'],
  approveMovement: ['gestor', 'admin'],
  cancelMovement: ['gestor', 'admin'],
  cancelBeforeSa: ['almoxarife', 'gestor', 'admin'],
  correctMovement: ['gestor', 'admin'],
  replaceSignature: ['gestor', 'admin'],
  exportExcel: ['equipe_sa', 'gestor', 'admin'],
  viewDashboard: ['gestor', 'admin', 'equipe_sa', 'almoxarife'],
  viewAudit: ['gestor', 'admin'],
  printLabels: ['admin', 'gestor', 'almoxarife'],
  manageMasterData: ['admin', 'almoxarife'],
  manageWarehouses: ['admin'],
  manageUsers: ['admin'],
  manageSettings: ['admin'],
} as const satisfies Record<string, readonly AppRole[]>;

export type Permission = keyof typeof PERMISSIONS;

export function can(roles: readonly AppRole[], permission: Permission): boolean {
  const allowed = PERMISSIONS[permission] as readonly AppRole[];
  return roles.some((r) => allowed.includes(r));
}

export const AUDIT_ACTION_LABELS: Record<string, string> = {
  'me.criada': 'ME criada',
  'me.finalizada': 'ME finalizada',
  'me.alterada': 'ME alterada',
  'me.aprovada': 'ME aprovada',
  'me.concluida': 'Baixa no ERP confirmada (ME concluída)',
  'me.cancelada': 'ME cancelada',
  'me.corrigida': 'Correção administrativa',
  'me.recebedor_alterado': 'Recebedor alterado',
  'me.impressa': 'ME impressa',
  'me.pdf_gerado': 'PDF gerado',
  'me.assinatura_consultada': 'Assinatura consultada',
  'item.incluido': 'Material incluído',
  'item.alterado': 'Quantidade alterada',
  'item.excluido': 'Material excluído',
  'assinatura.capturada': 'Assinatura capturada',
  'assinatura.substituida': 'Assinatura substituída',
  'sa.inclusao': 'SA registrada',
  'sa.correcao': 'Correção de SA registrada',
  'sa.informada': 'SA informada',
  'sa.corrigida': 'SA corrigida',
  'exportacao.excel': 'Exportação para Excel',
  'etiquetas.impressas': 'Etiquetas impressas',
  'qr.leitura_nao_encontrada': 'QR Code não localizado',
};

export function auditLabel(action: string): string {
  if (AUDIT_ACTION_LABELS[action]) return AUDIT_ACTION_LABELS[action];
  const [entity, op] = action.split('.');
  const opLabel = op === 'criado' ? 'criado' : op === 'alterado' ? 'alterado' : op === 'excluido' ? 'excluído' : op;
  return `${ENTITY_LABELS[entity] ?? entity}: ${opLabel}`;
}

export const ENTITY_LABELS: Record<string, string> = {
  stock_movements: 'ME',
  stock_movement_items: 'Item da ME',
  signatures: 'Assinatura',
  erp_sa_records: 'SA',
  materials: 'Material',
  material_qr_codes: 'QR Code',
  employees: 'Funcionário',
  warehouses: 'Estoque',
  profiles: 'Usuário',
  user_roles: 'Perfil de acesso',
  user_warehouses: 'Vínculo de estoque',
  app_settings: 'Parâmetros',
  contracts: 'Contrato',
  sectors: 'Setor',
  service_fronts: 'Frente/equipamento',
  service_orders: 'Ordem de serviço',
  fixed_assets: 'Ativo fixo',
  application_locations: 'Local de aplicação',
  accounts: 'Conta',
  material_categories: 'Categoria',
  interface: 'Interface',
};

export const LOOKUP_TABLES = [
  { table: 'contracts', label: 'Contratos', singular: 'contrato' },
  { table: 'sectors', label: 'Setores', singular: 'setor' },
  { table: 'service_fronts', label: 'Frentes de serviço / equipamentos', singular: 'frente/equipamento' },
  { table: 'service_orders', label: 'Ordens de serviço', singular: 'ordem de serviço' },
  { table: 'fixed_assets', label: 'Ativos fixos', singular: 'ativo fixo' },
  { table: 'application_locations', label: 'Locais de aplicação', singular: 'local de aplicação' },
  { table: 'accounts', label: 'Contas', singular: 'conta' },
  { table: 'material_categories', label: 'Categorias de material', singular: 'categoria' },
] as const;

export type LookupTable = (typeof LOOKUP_TABLES)[number]['table'];

export const NOT_FOUND_MATERIAL_MESSAGE =
  'Material não localizado. Verifique o QR Code ou realize uma pesquisa manual.';
