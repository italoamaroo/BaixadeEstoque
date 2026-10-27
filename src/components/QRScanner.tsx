import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Camera, CameraOff, Keyboard, RefreshCw } from 'lucide-react';
import type { Html5Qrcode } from 'html5-qrcode';
import { Button } from './ui/Button';
import { Alert } from './ui/Card';

interface Props {
  onScan: (code: string) => void;
  /** pausa a leitura (ex.: enquanto o usuário confirma quantidades) */
  paused?: boolean;
  autoStart?: boolean;
}

type CameraState = 'idle' | 'starting' | 'running' | 'error';

function cameraErrorMessage(err: unknown): string {
  const name = (err as { name?: string })?.name ?? '';
  const msg = String((err as { message?: string })?.message ?? err ?? '');
  if (typeof window !== 'undefined' && !window.isSecureContext) {
    return 'A câmera só funciona em conexão segura (HTTPS). Abra o sistema pelo endereço https://.';
  }
  if (name === 'NotAllowedError' || /permission|denied|NotAllowed/i.test(msg)) {
    return 'Permissão da câmera negada. Libere o acesso à câmera nas configurações do navegador e toque em "Tentar novamente".';
  }
  if (name === 'NotFoundError' || /no camera|NotFound|Requested device not found/i.test(msg)) {
    return 'Nenhuma câmera encontrada neste dispositivo. Use a digitação do código ou a pesquisa manual.';
  }
  if (name === 'NotReadableError' || /NotReadable|in use|Could not start video/i.test(msg)) {
    return 'A câmera está em uso por outro aplicativo. Feche-o e tente novamente.';
  }
  return 'Não foi possível iniciar a câmera. Use a digitação do código ou a pesquisa manual.';
}

/**
 * Leitor de QR Code pela câmera traseira (html5-qrcode).
 * Ignora leituras repetidas do mesmo código em sequência (2,5 s).
 */
export function QRScanner({ onScan, paused, autoStart = true }: Props) {
  const rawId = useId();
  const elementId = `qr-${rawId.replace(/[^a-zA-Z0-9]/g, '')}`;
  const scanner = useRef<Html5Qrcode | null>(null);
  const last = useRef<{ code: string; at: number }>({ code: '', at: 0 });
  const pausedRef = useRef(paused);
  const onScanRef = useRef(onScan);
  const [state, setState] = useState<CameraState>('idle');
  const [error, setError] = useState<string | null>(null);
  const [manual, setManual] = useState('');
  const [showManual, setShowManual] = useState(false);

  pausedRef.current = paused;
  onScanRef.current = onScan;

  const stop = useCallback(async () => {
    const s = scanner.current;
    scanner.current = null;
    if (s) {
      try {
        if (s.isScanning) await s.stop();
        s.clear();
      } catch {
        /* já parado */
      }
    }
    setState('idle');
  }, []);

  const start = useCallback(async () => {
    setError(null);
    setState('starting');
    try {
      if (!window.isSecureContext) throw new Error('insecure');
      const { Html5Qrcode, Html5QrcodeSupportedFormats } = await import('html5-qrcode');
      await stop();
      const instance = new Html5Qrcode(elementId, { formatsToSupport: [Html5QrcodeSupportedFormats.QR_CODE], verbose: false });
      scanner.current = instance;
      await instance.start(
        { facingMode: 'environment' },
        {
          fps: 10,
          qrbox: (w: number, h: number) => {
            const size = Math.floor(Math.min(w, h) * 0.7);
            return { width: size, height: size };
          },
          aspectRatio: 1,
        },
        (decoded: string) => {
          if (pausedRef.current) return;
          const code = decoded.trim();
          const now = Date.now();
          if (code === last.current.code && now - last.current.at < 2500) return;
          last.current = { code, at: now };
          if (navigator.vibrate) navigator.vibrate(60);
          onScanRef.current(code);
        },
        () => {
          /* quadro sem QR: ignorar */
        },
      );
      setState('running');
    } catch (err) {
      scanner.current = null;
      setState('error');
      setError(cameraErrorMessage(err));
      setShowManual(true);
    }
  }, [elementId, stop]);

  useEffect(() => {
    if (autoStart) void start();
    return () => {
      void stop();
    };
  }, []);

  const submitManual = () => {
    const code = manual.trim();
    if (!code) return;
    last.current = { code, at: Date.now() };
    onScan(code);
    setManual('');
  };

  return (
    <div className="space-y-3">
      <div className="relative overflow-hidden rounded-xl bg-slate-900">
        <div id={elementId} className="aspect-square w-full [&_video]:!w-full [&_video]:object-cover" />
        {state !== 'running' && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center text-slate-200">
            {state === 'starting' ? (
              <>
                <Camera className="h-10 w-10 animate-pulse" />
                <p className="text-sm">Iniciando câmera…</p>
              </>
            ) : (
              <>
                <CameraOff className="h-10 w-10" />
                <p className="text-sm">{state === 'error' ? 'Câmera indisponível' : 'Câmera desligada'}</p>
                <Button variant="secondary" size="lg" icon={<RefreshCw className="h-5 w-5" />} onClick={() => void start()}>
                  {state === 'error' ? 'Tentar novamente' : 'Ligar câmera'}
                </Button>
              </>
            )}
          </div>
        )}
        {state === 'running' && paused && (
          <div className="absolute inset-0 flex items-center justify-center bg-slate-900/60 text-sm font-medium text-white">
            Leitura pausada
          </div>
        )}
      </div>

      {error && <Alert tone="warning">{error}</Alert>}

      <div className="flex flex-wrap gap-2">
        {state === 'running' ? (
          <Button variant="secondary" icon={<CameraOff className="h-4 w-4" />} onClick={() => void stop()}>
            Desligar câmera
          </Button>
        ) : null}
        <Button variant="ghost" icon={<Keyboard className="h-4 w-4" />} onClick={() => setShowManual((v) => !v)}>
          Digitar código
        </Button>
      </div>

      {showManual && (
        <form
          className="flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            submitManual();
          }}
        >
          <input
            className="h-12 min-w-0 flex-1 rounded-lg border-0 px-3 text-base ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-brand-600"
            placeholder="Código do QR ou do material"
            value={manual}
            onChange={(e) => setManual(e.target.value)}
            autoCapitalize="characters"
            autoComplete="off"
            inputMode="text"
            aria-label="Código do QR Code ou do material"
          />
          <Button type="submit" size="lg">
            Buscar
          </Button>
        </form>
      )}
    </div>
  );
}
