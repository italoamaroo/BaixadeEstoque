/**
 * Reconhecimento facial no próprio aparelho (a imagem do rosto nunca sai dele).
 * Gera a "impressão numérica" do rosto (128 números) que o servidor compara com o cadastro.
 * A biblioteca e os modelos (~7 MB) só são carregados quando a tela precisa deles.
 */
type FaceApi = typeof import('@vladmandic/face-api');

let loading: Promise<FaceApi> | null = null;

export function loadFaceApi(): Promise<FaceApi> {
  if (!loading) {
    loading = (async () => {
      const faceapi = await import('@vladmandic/face-api');
      const tf = faceapi.tf as unknown as { setBackend(b: string): Promise<boolean>; ready(): Promise<void> };
      try {
        if (!(await tf.setBackend('webgl'))) await tf.setBackend('cpu');
      } catch {
        await tf.setBackend('cpu');
      }
      await tf.ready();
      const base = `${import.meta.env.BASE_URL ?? '/'}models/face`.replace('//', '/');
      await Promise.all([
        faceapi.nets.tinyFaceDetector.loadFromUri(base),
        faceapi.nets.faceLandmark68TinyNet.loadFromUri(base),
        faceapi.nets.faceRecognitionNet.loadFromUri(base),
      ]);
      return faceapi;
    })().catch((e) => {
      loading = null;
      throw e;
    });
  }
  return loading;
}

export type Descriptor = number[];

export interface FaceReading {
  descriptor: Descriptor;
  /** posição do rosto: negativo = virado para um lado, positivo = para o outro */
  yaw: number;
  score: number;
  box: { x: number; y: number; width: number; height: number };
}

type Point = { x: number; y: number };

/** Giro do rosto estimado pelos pontos: deslocamento do nariz em relação ao meio dos olhos. */
export function estimateYaw(points: Point[]): number {
  // pontos do modelo de 68: olhos 36-41 e 42-47, ponta do nariz 30
  const avg = (a: Point[]) => ({ x: a.reduce((s, p) => s + p.x, 0) / a.length, y: a.reduce((s, p) => s + p.y, 0) / a.length });
  const le = avg(points.slice(36, 42));
  const re = avg(points.slice(42, 48));
  const nose = points[30];
  const dist = Math.hypot(re.x - le.x, re.y - le.y) || 1;
  return (nose.x - (le.x + re.x) / 2) / dist;
}

const round = (d: Float32Array): Descriptor => Array.from(d, (v) => Math.round(v * 1e5) / 1e5);

/** Lê o maior rosto de uma imagem, vídeo ou canvas. */
export async function readFace(input: HTMLImageElement | HTMLVideoElement | HTMLCanvasElement, inputSize = 320): Promise<FaceReading | null> {
  const faceapi = await loadFaceApi();
  const opts = new faceapi.TinyFaceDetectorOptions({ inputSize, scoreThreshold: 0.5 });
  const all = await faceapi.detectAllFaces(input, opts).withFaceLandmarks(true).withFaceDescriptors();
  if (!all.length) return null;
  all.sort((a, b) => b.detection.box.area - a.detection.box.area);
  const f = all[0];
  const b = f.detection.box;
  return {
    descriptor: round(f.descriptor),
    yaw: estimateYaw(f.landmarks.positions),
    score: f.detection.score,
    box: { x: b.x, y: b.y, width: b.width, height: b.height },
  };
}

/** Média de várias leituras do mesmo rosto (mais estável que uma só). */
export function averageDescriptor(list: Descriptor[]): Descriptor {
  const out = new Array(128).fill(0);
  for (const d of list) for (let i = 0; i < 128; i++) out[i] += d[i] / list.length;
  return out.map((v) => Math.round(v * 1e5) / 1e5);
}

/** Lê o rosto de um arquivo de foto (cadastro em lote). Fotos grandes são reduzidas antes. */
export async function readFaceFromFile(file: File): Promise<FaceReading | null> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((res, rej) => {
      const i = new Image();
      i.onload = () => res(i);
      i.onerror = () => rej(new Error('Imagem inválida'));
      i.src = url;
    });
    const k = Math.min(1, 640 / Math.max(img.naturalWidth, img.naturalHeight));
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(img.naturalWidth * k));
    c.height = Math.max(1, Math.round(img.naturalHeight * k));
    c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
    return await readFace(c, 416);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** Liveness simples: a pessoa vira o rosto de um lado para o outro (foto parada não passa). */
export const LIVENESS_YAW_RANGE = 0.22;
/** Rosto de frente: usado para gerar a impressão numérica. */
export const FRONTAL_YAW = 0.15;
