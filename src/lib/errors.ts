/** Converte erros do Supabase/PostgreSQL/rede em mensagens claras em português. */
export class AppError extends Error {
  code?: string;
  isNetwork: boolean;
  constructor(message: string, opts: { code?: string; isNetwork?: boolean } = {}) {
    super(message);
    this.name = 'AppError';
    this.code = opts.code;
    this.isNetwork = Boolean(opts.isNetwork);
  }
}

interface ErrorLike {
  message?: string;
  code?: string;
  details?: string;
  hint?: string;
  status?: number;
  statusCode?: string | number;
  error?: string;
  name?: string;
}

const NETWORK_PATTERNS = [/failed to fetch/i, /networkerror/i, /network request failed/i, /load failed/i, /fetch failed/i, /timeout/i, /ERR_INTERNET/i];

export function isNetworkError(err: unknown): boolean {
  if (err instanceof AppError) return err.isNetwork;
  const msg = (err as ErrorLike)?.message ?? String(err ?? '');
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return true;
  return NETWORK_PATTERNS.some((re) => re.test(msg));
}

export function toAppError(err: unknown, fallback = 'Não foi possível concluir a operação.'): AppError {
  if (err instanceof AppError) return err;
  const e = (err ?? {}) as ErrorLike;
  const msg = e.message ?? (typeof err === 'string' ? err : '');

  if (isNetworkError(err)) {
    return new AppError('Sem conexão com o servidor. Verifique a internet e tente novamente — os dados preenchidos foram mantidos.', {
      isNetwork: true,
    });
  }

  if (/JWT expired|invalid JWT|refresh token/i.test(msg)) {
    return new AppError('Sua sessão expirou. Entre novamente.', { code: 'session' });
  }
  if (/Invalid login credentials/i.test(msg)) {
    return new AppError('E-mail ou senha incorretos.', { code: 'auth' });
  }
  if (/Email not confirmed/i.test(msg)) {
    return new AppError('E-mail ainda não confirmado. Verifique sua caixa de entrada.', { code: 'auth' });
  }
  if (/row-level security|permission denied/i.test(msg) || e.code === '42501') {
    // Mensagens das funções RPC já são explicativas; as do PostgREST não.
    if (e.code === '42501' && msg && !/permission denied|row-level/i.test(msg)) {
      return new AppError(msg, { code: e.code });
    }
    return new AppError('Você não tem permissão para realizar esta operação.', { code: '42501' });
  }
  if (e.code === '23505' || /duplicate key/i.test(msg)) {
    if (/materials_code_uk/.test(msg)) return new AppError('Já existe um material com este código.', { code: '23505' });
    if (/qr_code/.test(msg)) return new AppError('Este QR Code já está em uso.', { code: '23505' });
    if (/registration/.test(msg)) return new AppError('Já existe um funcionário com esta matrícula.', { code: '23505' });
    if (/_code_uk/.test(msg)) return new AppError('Já existe um registro com este código.', { code: '23505' });
    if (/^duplicate key/i.test(msg)) return new AppError('Registro duplicado.', { code: '23505' });
    return new AppError(msg, { code: '23505' });
  }
  if (e.code === '23514' || /violates check constraint/i.test(msg)) {
    return new AppError('Algum campo está em formato inválido. Revise os dados informados.', { code: '23514' });
  }
  if (e.code === 'P0001' || e.code === 'P0002' || e.code === '22023') {
    return new AppError(msg, { code: e.code });
  }
  if (/The resource already exists|Duplicate/i.test(msg)) {
    return new AppError('O arquivo já foi enviado.', { code: 'storage_duplicate' });
  }
  if (/Payload too large|exceeded the maximum allowed size/i.test(msg)) {
    return new AppError('Arquivo maior que o permitido.', { code: 'storage_size' });
  }
  return new AppError(msg || fallback, { code: e.code });
}

export function errorMessage(err: unknown, fallback?: string): string {
  return toAppError(err, fallback).message;
}
