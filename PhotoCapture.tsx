import { useCallback, useEffect, useRef, useState } from 'react';
import { Camera, CameraOff, RotateCcw } from 'lucide-react';
import { Button } from './ui/Button';
import { Alert } from './ui/Card';
import { Spinner } from './ui/Spinner';

/**
 * Foto do solicitante pela câmera frontal (tablet/celular).
 * Gera JPEG de até 800 px. onCapture(null) quando a foto é descartada.
 */
export function PhotoCapture({
  onCapture,
  onCameraUnavailable,
}: {
  onCapture: (blob: Blob | null, dataUrl: string | null) => void;
  onCameraUnavailable: (reason: string) => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [state, setState] = useState<'starting' | 'live' | 'taken' | 'error'>('starting');
  const [preview, setPreview] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const stop = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
  }, []);

  const start = useCallback(async () => {
    setState('starting');
    setError(null);
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('Este navegador não permite usar a câmera.');
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 960 } },
        audio: false,
      });
      streamRef.current = stream;
      if (videoRef.current) {
        videoRef.current.srcObject = stream;
        await videoRef.current.play().catch(() => undefined);
      }
      setState('live');
    } catch (e) {
      const err = e as DOMException;
      const msg =
        err?.name === 'NotAllowedError'
          ? 'Permissão da câmera negada. Libere a câmera para este site nas configurações do navegador.'
          : err?.name === 'NotFoundError' || err?.name === 'OverconstrainedError'
            ? 'Nenhuma câmera encontrada neste aparelho.'
            : err?.message || 'Não foi possível abrir a câmera.';
      setError(msg);
      setState('error');
      onCameraUnavailable(msg);
    }
  }, [onCameraUnavailable]);

  useEffect(() => {
    void start();
    return stop;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const take = () => {
    const v = videoRef.current;
    if (!v || !v.videoWidth) return;
    const scale = Math.min(1, 800 / Math.max(v.videoWidth, v.videoHeight));
    const c = document.createElement('canvas');
    c.width = Math.round(v.videoWidth * scale);
    c.height = Math.round(v.videoHeight * scale);
    const ctx = c.getContext('2d');
    if (!ctx) return;
    // espelha como no visor da câmera frontal
    ctx.translate(c.width, 0);
    ctx.scale(-1, 1);
    ctx.drawImage(v, 0, 0, c.width, c.height);
    const dataUrl = c.toDataURL('image/jpeg', 0.82);
    c.toBlob(
      (blob) => {
        if (!blob) return;
        setPreview(dataUrl);
        setState('taken');
        stop();
        onCapture(blob, dataUrl);
      },
      'image/jpeg',
      0.82,
    );
  };

  const retake = () => {
    setPreview(null);
    onCapture(null, null);
    void start();
  };

  return (
    <div className="space-y-3">
      <div className="relative mx-auto aspect-[4/3] w-full max-w-md overflow-hidden rounded-2xl bg-slate-900">
        {state === 'taken' && preview ? (
          <img src={preview} alt="Foto do solicitante" className="h-full w-full object-cover" />
        ) : (
          <video ref={videoRef} playsInline muted className="h-full w-full -scale-x-100 object-cover" />
        )}
        {state === 'starting' && (
          <div className="absolute inset-0 flex items-center justify-center">
            <Spinner className="h-8 w-8 text-white" />
          </div>
        )}
        {state === 'error' && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 p-4 text-center text-white">
            <CameraOff className="h-10 w-10" />
            <p className="text-sm">Câmera indisponível</p>
          </div>
        )}
        {state === 'live' && (
          <div className="pointer-events-none absolute inset-6 rounded-[45%] border-4 border-white/50" aria-hidden />
        )}
      </div>
      {error && <Alert tone="warning">{error}</Alert>}
      <div className="flex justify-center gap-2">
        {state === 'live' && (
          <Button size="lg" icon={<Camera className="h-5 w-5" />} onClick={take}>
            Tirar foto
          </Button>
        )}
        {state === 'taken' && (
          <Button variant="secondary" size="lg" icon={<RotateCcw className="h-5 w-5" />} onClick={retake}>
            Tirar outra
          </Button>
        )}
        {state === 'error' && (
          <Button variant="secondary" icon={<RotateCcw className="h-4 w-4" />} onClick={() => void start()}>
            Tentar de novo
          </Button>
        )}
      </div>
    </div>
  );
}
