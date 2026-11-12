import { useEffect, useRef, useState } from 'react';
import clsx from 'clsx';
import { Camera, RotateCcw, ScanFace } from 'lucide-react';
import { averageDescriptor, FRONTAL_YAW, LIVENESS_YAW_RANGE, loadFaceApi, readFace, type Descriptor } from '@/lib/face';
import { Button } from '@/components/ui/Button';

export interface FaceScanResult {
  /** média das leituras de frente */
  descriptor: Descriptor;
  /** leituras individuais (cadastro guarda até 5) */
  samples: Descriptor[];
  /** a pessoa virou o rosto (não é foto parada) */
  liveness: boolean;
}

type Phase = 'carregando' | 'frente' | 'virar' | 'pronto' | 'erro' | 'tempo';

/**
 * Câmera ao vivo que lê o rosto no próprio aparelho.
 * 1) olhar de frente (coleta leituras); 2) virar o rosto devagar (prova de vida).
 * Nada é gravado: só a impressão numérica vai para quem chamou.
 */
export function FaceScanner({
  samplesNeeded = 3,
  requireLiveness = true,
  timeoutMs = 25000,
  onResult,
  onUnavailable,
  className,
}: {
  samplesNeeded?: number;
  requireLiveness?: boolean;
  timeoutMs?: number;
  onResult: (r: FaceScanResult) => void;
  onUnavailable?: (reason: string) => void;
  className?: string;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const [phase, setPhase] = useState<Phase>('carregando');
  const [hint, setHint] = useState('Preparando a câmera…');
  const [progress, setProgress] = useState(0);
  const [run, setRun] = useState(0);
  const done = useRef(onResult);
  done.current = onResult;
  const unavailable = useRef(onUnavailable);
  unavailable.current = onUnavailable;

  useEffect(() => {
    let alive = true;
    let stream: MediaStream | null = null;
    const samples: Descriptor[] = [];
    let minYaw = Infinity;
    let maxYaw = -Infinity;
    setPhase('carregando');
    setProgress(0);
    setHint('Preparando a câmera…');

    const stop = () => {
      alive = false;
      stream?.getTracks().forEach((t) => t.stop());
    };

    (async () => {
      try {
        if (!navigator.mediaDevices?.getUserMedia) throw new Error('Este aparelho não permite usar a câmera aqui.');
        const [s] = await Promise.all([
          navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 } }, audio: false }),
          loadFaceApi(),
        ]);
        stream = s;
        if (!alive) return stop();
        const v = video.current!;
        v.srcObject = s;
        await v.play().catch(() => undefined);
        setPhase('frente');
        setHint('Olhe para a câmera, de frente');
        const started = Date.now();
        while (alive) {
          if (Date.now() - started > timeoutMs) {
            setPhase('tempo');
            setHint('Não consegui ler o rosto a tempo.');
            stream.getTracks().forEach((t) => t.stop());
            return;
          }
          const r = v.readyState >= 2 ? await readFace(v).catch(() => null) : null;
          if (!alive) return;
          if (!r) {
            setHint(samples.length < samplesNeeded ? 'Centralize o rosto na tela, com boa luz' : 'Vire o rosto devagar para um lado e volte');
          } else {
            minYaw = Math.min(minYaw, r.yaw);
            maxYaw = Math.max(maxYaw, r.yaw);
            if (samples.length < samplesNeeded) {
              if (Math.abs(r.yaw) <= FRONTAL_YAW && r.score >= 0.6) samples.push(r.descriptor);
              setHint('Olhe para a câmera, de frente');
            }
            const live = maxYaw - minYaw >= LIVENESS_YAW_RANGE;
            const pFront = Math.min(1, samples.length / samplesNeeded);
            const pLive = requireLiveness ? Math.min(1, Math.max(0, maxYaw - minYaw) / LIVENESS_YAW_RANGE) : 1;
            setProgress(Math.round(((pFront + pLive) / 2) * 100));
            if (samples.length >= samplesNeeded) {
              if (!requireLiveness || live) {
                setPhase('pronto');
                setHint('Pronto!');
                stream.getTracks().forEach((t) => t.stop());
                done.current({ descriptor: averageDescriptor(samples), samples: [...samples], liveness: live });
                return;
              }
              setPhase('virar');
              setHint('Agora vire o rosto devagar para um lado e volte');
            }
          }
          await new Promise((res) => setTimeout(res, 120));
        }
      } catch (e) {
        if (!alive) return;
        const msg =
          e instanceof DOMException && (e.name === 'NotAllowedError' || e.name === 'SecurityError')
            ? 'A câmera foi bloqueada. Libere o acesso à câmera nas permissões do navegador.'
            : e instanceof DOMException && e.name === 'NotFoundError'
              ? 'Nenhuma câmera encontrada neste aparelho.'
              : e instanceof Error
                ? e.message
                : 'Não foi possível usar a câmera.';
        setPhase('erro');
        setHint(msg);
        unavailable.current?.(msg);
      }
    })();
    return stop;
  }, [run, samplesNeeded, requireLiveness, timeoutMs]);

  return (
    <div className={clsx('space-y-3', className)}>
      <div className="relative mx-auto aspect-[4/3] w-full max-w-md overflow-hidden rounded-2xl bg-slate-900">
        <video ref={video} playsInline muted className="h-full w-full -scale-x-100 object-cover" />
        <div
          className={clsx(
            'pointer-events-none absolute inset-[12%] rounded-[45%] border-4 transition-colors',
            phase === 'pronto' ? 'border-emerald-400' : phase === 'virar' ? 'border-amber-300' : 'border-white/70',
          )}
        />
        {phase === 'carregando' && (
          <div className="absolute inset-0 grid place-items-center text-white">
            <ScanFace className="h-12 w-12 animate-pulse" />
          </div>
        )}
      </div>
      <div className="mx-auto max-w-md">
        <div className="h-2 overflow-hidden rounded-full bg-slate-200" role="progressbar" aria-valuenow={progress} aria-valuemin={0} aria-valuemax={100}>
          <div className={clsx('h-full transition-all', phase === 'pronto' ? 'bg-emerald-500' : 'bg-brand-600')} style={{ width: `${progress}%` }} />
        </div>
        <p
          className={clsx('mt-2 text-center text-lg font-semibold', phase === 'erro' || phase === 'tempo' ? 'text-red-700' : 'text-slate-800')}
          aria-live="polite"
        >
          {hint}
        </p>
        {(phase === 'tempo' || phase === 'erro') && (
          <div className="mt-2 flex justify-center">
            <Button variant="secondary" icon={phase === 'erro' ? <Camera className="h-4 w-4" /> : <RotateCcw className="h-4 w-4" />} onClick={() => setRun((n) => n + 1)}>
              Tentar de novo
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
