import { useCallback, useEffect, useRef } from 'react';

/**
 * Captura contínua de leitor QR/código de barras que funciona como teclado (HID).
 *
 * - O campo de leitura (inputRef) fica sempre em foco; se perder o foco, volta sozinho
 *   (a menos que outro campo esteja sendo editado de propósito ou haja um modal aberto).
 * - Fora do campo, um "ouvinte" global reconhece a leitura pelo ritmo das teclas
 *   (o leitor digita muito mais rápido que uma pessoa) e pelo Enter no final.
 * - Leituras iguais em menos de `repeatMs` são ignoradas (bipada dupla acidental).
 */
export interface HidScannerOptions {
  enabled: boolean;
  onScan: (code: string) => void;
  onRepeatIgnored?: (code: string) => void;
  /** intervalo máximo entre teclas para considerar que é o leitor (ms) */
  maxKeyIntervalMs?: number;
  /** tamanho mínimo do código */
  minLength?: number;
  /** janela para ignorar a mesma leitura repetida (ms) */
  repeatMs?: number;
}

const EDITABLE = 'input, textarea, select, [contenteditable="true"]';

export function useHidScanner(inputRef: React.RefObject<HTMLInputElement | null>, opts: HidScannerOptions) {
  const { enabled, maxKeyIntervalMs = 45, minLength = 3, repeatMs = 1500 } = opts;
  const onScan = useRef(opts.onScan);
  const onRepeat = useRef(opts.onRepeatIgnored);
  onScan.current = opts.onScan;
  onRepeat.current = opts.onRepeatIgnored;
  const last = useRef<{ code: string; at: number }>({ code: '', at: 0 });
  const buffer = useRef<{ text: string; lastKey: number }>({ text: '', lastKey: 0 });

  const emit = useCallback(
    (raw: string) => {
      const code = raw.trim();
      if (code.length < minLength) return;
      const now = Date.now();
      if (code === last.current.code && now - last.current.at < repeatMs) {
        onRepeat.current?.(code);
        return;
      }
      last.current = { code, at: now };
      onScan.current(code);
    },
    [minLength, repeatMs],
  );

  const focus = useCallback(() => {
    const el = inputRef.current;
    if (!el || !enabled) return;
    const active = document.activeElement as HTMLElement | null;
    // não rouba o foco de outro campo que o operador está editando nem de um modal aberto
    if (active && active !== el && active !== document.body && active.matches(EDITABLE)) return;
    if (document.querySelector('[role="dialog"]')) return;
    if (active === el) return;
    // leitura em andamento fora do campo: leva o que já foi lido para o campo,
    // para o código não ser partido ao meio quando o foco voltar
    const b = buffer.current;
    if (b.text && Date.now() - b.lastKey < maxKeyIntervalMs * 4) {
      el.value = b.text;
    }
    b.text = '';
    el.focus({ preventScroll: true });
  }, [enabled, inputRef, maxKeyIntervalMs]);

  // Enter no campo de leitura
  const onInputKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter' || e.key === 'Tab') {
        e.preventDefault();
        const value = e.currentTarget.value;
        e.currentTarget.value = '';
        emit(value);
      }
    },
    [emit],
  );

  // Ouvinte global: leitura feita com o foco fora de qualquer campo
  useEffect(() => {
    if (!enabled) return;
    const handler = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (target === inputRef.current) return; // o próprio campo trata
      if (target && target.matches?.(EDITABLE)) return; // outro campo em edição: não interfere
      if (e.ctrlKey || e.altKey || e.metaKey) return;
      const now = Date.now();
      const b = buffer.current;
      if (e.key === 'Enter') {
        if (b.text.length >= minLength && now - b.lastKey <= maxKeyIntervalMs * 4) {
          e.preventDefault();
          emit(b.text);
        }
        b.text = '';
        return;
      }
      if (e.key.length !== 1) return;
      if (now - b.lastKey > maxKeyIntervalMs * 4) b.text = '';
      b.text += e.key;
      b.lastKey = now;
    };
    window.addEventListener('keydown', handler, true);
    return () => window.removeEventListener('keydown', handler, true);
  }, [enabled, emit, inputRef, maxKeyIntervalMs, minLength]);

  // Mantém o foco no campo de leitura
  useEffect(() => {
    if (!enabled) return;
    focus();
    const t = setInterval(focus, 1000);
    const onVisible = () => focus();
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('focus', onVisible);
    return () => {
      clearInterval(t);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', onVisible);
    };
  }, [enabled, focus]);

  return { onInputKeyDown, focus, onInputBlur: () => setTimeout(focus, 250) };
}

/** Teclados configurados como US em Windows ABNT2 trocam alguns símbolos no código lido. */
export function normalizeScannedCode(raw: string): string {
  return raw
    .trim()
    .replace(/^[\u0000-\u001f]+|[\u0000-\u001f]+$/g, '')
    .replace(/[‐‑‒–—]/g, '-');
}
