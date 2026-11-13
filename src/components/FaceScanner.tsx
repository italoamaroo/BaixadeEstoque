import { useEffect, useRef, useState } from 'react';
import clsx from 'clsx';
import { Camera, RotateCcw, ScanFace } from 'lucide-react';
import { averageDescriptor, describeFace, detectFace, FRONTAL_YAW, LIVENESS_YAW_RANGE, prepareFace, type Descriptor } from '@/lib/face';
import { Button } from '@/components/ui/Button';

export interface FaceScanResult {
  /** média das leituras de frente */
  descriptor: Descriptor;
  /** leituras individuais (cadastro guarda até 5) */
  samples: Descriptor[];
  /** a pessoa virou o rosto (não é foto parada) */
  liveness: boolean;
}

/** Leituras de frente que concordam entre si (descarta quadros borrados ou distorcidos). */
const MAX_SPREAD = 0.35;
const dist = (a: Descriptor, b: Descriptor) => {
  let d = 0;
  for (let k = 0; k < 128; k++) d += (a[k] - b[k]) ** 2;
  return Math.sqrt(d);
};
/** Escolhe `needed` leituras que concordam todas entre si, ou null se ainda não há. */
function pickConsistent(list: Descriptor[], needed: number): Descriptor[] | null {
  if (list.length < needed) return null;
  for (let i = list.length - 1; i >= 0; i--) {
    const near = list
      .map((d, j) => ({ d, j, x: dist(list[i], d) }))
      .filter((o) => o.x <= MAX_SPREAD)
      .sort((a, b) => a.x - b.x)
      .slice(0, needed);
    if (near.length < needed) continue;
    const ok = near.every((a, ai) => near.every((b, bi) => bi <= ai || dist(a.d, b.d) <= MAX_SPREAD));
    if (ok) return near.map((o) => o.d);
  }
  return null;
}
const consistent = (list: Descriptor[], needed: number) => pickConsistent(list, needed) !== null;

type Phase = 'carregando' | 'frente' | 'virar' | 'pronto' | 'erro' | 'tempo';
type Box = { left: number; top: number; size: number };

/**
 * Câmera ao vivo que lê o rosto no próprio aparelho.
 * Olhar de frente (gera a impressão numérica) e virar o rosto devagar (prova de vida), em qualquer ordem.
 * Um círculo acompanha o rosto na tela. Nada é gravado: só a impressão numérica vai para quem chamou.
 */
export function FaceScanner({
  samplesNeeded = 2,
  requireLiveness = true,
  timeoutMs = 20000,
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
  const [box, setBox] = useState<Box | null>(null);
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
    setBox(null);
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
          prepareFace(),
        ]);
        stream = s;
        if (!alive) return stop();
        const v = video.current!;
        v.srcObject = s;
        await v.play().catch(() => undefined);
        setPhase('frente');
        setHint('Olhe para a câmera');
        const started = Date.now();
        while (alive) {
          if (Date.now() - started > timeoutMs) {
            setPhase('tempo');
            setBox(null);
            setHint('Não consegui ler o rosto a tempo.');
            stream.getTracks().forEach((t) => t.stop());
            return;
          }
          const r = v.readyState >= 2 ? await detectFace(v).catch(() => null) : null;
          if (!alive) return;
          if (!r) {
            setBox(null);
            setHint('Centralize o rosto na tela, com boa luz');
          } else {
            // círculo que acompanha o rosto (a imagem aparece espelhada)
            const size = Math.max(r.box.width, r.box.height * 0.75) * 1.35;
            const cx = 1 - (r.box.x + r.box.width / 2);
            const cy = r.box.y + r.box.height / 2;
            setBox({ left: cx - size / 2, top: cy - (size * 4) / 3 / 2, size });
            minYaw = Math.min(minYaw, r.yaw);
            maxYaw = Math.max(maxYaw, r.yaw);
            const front = consistent(samples, samplesNeeded);
            if (!front && Math.abs(r.yaw) <= FRONTAL_YAW && r.score >= 0.6) {
              // a parte pesada só nos quadros de frente, e só até ter leituras que concordam
              const d = await describeFace(v, r).catch(() => null);
              if (!alive) return;
              if (d) {
                samples.push(d);
                if (samples.length > 8) samples.shift();
              }
            }
            const ok = consistent(samples, samplesNeeded);
            const live = maxYaw - minYaw >= LIVENESS_YAW_RANGE;
            const pFront = ok ? 1 : Math.min(0.9, samples.length / samplesNeeded);
            const pLive = requireLiveness ? Math.min(1, Math.max(0, maxYaw - minYaw) / LIVENESS_YAW_RANGE) : 1;
            setProgress(Math.round(((pFront + pLive) / 2) * 100));
            if (ok && (!requireLiveness || live)) {
              setPhase('pronto');
              setHint('Pronto!');
              stream.getTracks().forEach((t) => t.stop());
              const chosen = pickConsistent(samples, samplesNeeded) ?? samples;
              done.current({ descriptor: averageDescriptor(chosen), samples: chosen.slice(0, 5), liveness: live });
              return;
            }
            if (ok) {
              setPhase('virar');
              setHint('Agora vire o rosto devagar para um lado');
            } else {
              setPhase('frente');
              setHint(Math.abs(r.yaw) > FRONTAL_YAW ? 'Agora olhe de frente para a câmera' : 'Olhe para a câmera');
            }
          }
          // libera a tela entre uma leitura e outra (o vídeo continua fluido)
          await new Promise((res) => requestAnimationFrame(() => res(null)));
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

  const ring = phase === 'pronto' ? 'border-emerald-400' : phase === 'virar' ? 'border-amber-300' : 'border-sky-300';
  return (
    <div className={clsx('space-y-3', className)}>
      <div className="relative mx-auto aspect-[4/3] w-full max-w-md overflow-hidden rounded-2xl bg-slate-900">
        <video ref={video} playsInline muted className="h-full w-full -scale-x-100 object-cover" />
        {box ? (
          <div
            className={clsx('pointer-events-none absolute rounded-full border-4 transition-all duration-150 ease-out', ring)}
            style={{ left: `${box.left * 100}%`, top: `${box.top * 100}%`, width: `${box.size * 100}%`, aspectRatio: '1 / 1' }}
            data-testid="face-ring"
          />
        ) : (
          phase !== 'carregando' && (
            <div className="pointer-events-none absolute left-1/2 top-1/2 aspect-square h-[70%] -translate-x-1/2 -translate-y-1/2 rounded-full border-4 border-dashed border-white/60" />
          )
        )}
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
