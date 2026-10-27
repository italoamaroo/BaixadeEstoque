import { useEffect, useState } from 'react';
import QRCode from 'qrcode';

/** Gera o QR Code no navegador. O conteúdo é somente o identificador do material. */
export function QRCodeImage({ value, size = 160, className }: { value: string; size?: number; className?: string }) {
  const [src, setSrc] = useState<string>('');
  useEffect(() => {
    let alive = true;
    QRCode.toDataURL(value, { errorCorrectionLevel: 'M', margin: 1, width: size * 2, color: { dark: '#000000', light: '#ffffff' } })
      .then((url) => alive && setSrc(url))
      .catch(() => alive && setSrc(''));
    return () => {
      alive = false;
    };
  }, [value, size]);
  if (!src) return <div style={{ width: size, height: size }} className="animate-pulse rounded bg-slate-100" />;
  return <img src={src} width={size} height={size} alt={`QR Code ${value}`} className={className} />;
}

export async function qrDataUrl(value: string, size = 600): Promise<string> {
  return QRCode.toDataURL(value, { errorCorrectionLevel: 'M', margin: 2, width: size });
}
