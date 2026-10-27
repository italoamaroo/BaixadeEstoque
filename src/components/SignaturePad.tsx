import { useCallback, useEffect, useRef, useState } from 'react';
import SignaturePadLib from 'signature_pad';
import { Eraser } from 'lucide-react';
import { Button } from './ui/Button';
import { inkRatio } from '@/lib/signature';

interface Props {
  onChange: (isEmpty: boolean) => void;
  /** recebe uma função que exporta a imagem PNG (ou null se vazia) */
  registerExporter: (fn: () => string | null) => void;
  initialDataUrl?: string | null;
  disabled?: boolean;
}

/** Área de assinatura em canvas para dedo ou caneta (signature_pad). */
export function SignaturePad({ onChange, registerExporter, initialDataUrl, disabled }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const padRef = useRef<SignaturePadLib | null>(null);
  const [empty, setEmpty] = useState(true);

  const resize = useCallback(() => {
    const canvas = canvasRef.current;
    const pad = padRef.current;
    if (!canvas || !pad) return;
    const data = pad.isEmpty() ? null : pad.toData();
    const ratio = Math.max(window.devicePixelRatio || 1, 1);
    canvas.width = canvas.offsetWidth * ratio;
    canvas.height = canvas.offsetHeight * ratio;
    canvas.getContext('2d')?.scale(ratio, ratio);
    pad.clear();
    if (data) pad.fromData(data);
  }, []);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const pad = new SignaturePadLib(canvas, {
      minWidth: 0.8,
      maxWidth: 2.6,
      penColor: '#0f172a',
      backgroundColor: 'rgba(0,0,0,0)',
    });
    padRef.current = pad;
    const handleEnd = () => {
      const isEmpty = pad.isEmpty();
      setEmpty(isEmpty);
      onChange(isEmpty);
    };
    pad.addEventListener('endStroke', handleEnd);
    resize();
    if (initialDataUrl) {
      void pad.fromDataURL(initialDataUrl, { ratio: 1, width: canvas.offsetWidth, height: canvas.offsetHeight }).then(() => {
        setEmpty(false);
        onChange(false);
      });
    }
    registerExporter(() => {
      if (pad.isEmpty()) return null;
      // rejeita "assinaturas" que são só um ponto ou risco mínimo
      if (inkRatio(canvas) < 0.0015) return null;
      return pad.toDataURL('image/png');
    });
    window.addEventListener('resize', resize);
    return () => {
      window.removeEventListener('resize', resize);
      pad.removeEventListener('endStroke', handleEnd);
      pad.off();
    };
  }, []);

  useEffect(() => {
    const pad = padRef.current;
    if (!pad) return;
    if (disabled) pad.off();
    else pad.on();
  }, [disabled]);

  const clear = () => {
    padRef.current?.clear();
    setEmpty(true);
    onChange(true);
  };

  return (
    <div className="space-y-2">
      <div className="relative rounded-xl border-2 border-dashed border-slate-300 bg-white">
        <canvas
          ref={canvasRef}
          className="block h-56 w-full touch-none sm:h-64"
          aria-label="Área de assinatura. Assine com o dedo ou caneta."
          role="img"
        />
        {empty && (
          <span className="pointer-events-none absolute inset-0 flex items-center justify-center text-slate-400">
            Assine aqui
          </span>
        )}
        <div className="pointer-events-none absolute bottom-10 left-6 right-6 border-b border-slate-300" />
      </div>
      <div className="flex justify-end">
        <Button variant="secondary" icon={<Eraser className="h-4 w-4" />} onClick={clear} disabled={disabled}>
          Limpar
        </Button>
      </div>
    </div>
  );
}
