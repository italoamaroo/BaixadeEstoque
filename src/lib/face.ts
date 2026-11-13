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
      // modelos na raiz de public/ (arquivos *_model.bin e *-weights_manifest.json)
      const base = (import.meta.env.BASE_URL ?? '/').replace(/\/$/, '') || '/';
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

/** Tamanho da imagem usada para achar o rosto ao vivo (menor = mais rápido). */
export const LIVE_INPUT_SIZE = 224;

export interface LiveDetection {
  yaw: number;
  score: number;
  /** caixa do rosto em fração da imagem (0 a 1), para desenhar o círculo que acompanha o rosto */
  box: { x: number; y: number; width: number; height: number };
  /** uso interno: região alinhada do rosto para gerar a impressão numérica */
  aligned: unknown;
}

/** Só acha o rosto e os pontos (rápido). A impressão numérica é gerada à parte, só quando precisa. */
export async function detectFace(input: HTMLVideoElement | HTMLCanvasElement): Promise<LiveDetection | null> {
  const faceapi = await loadFaceApi();
  const r = await faceapi.detectSingleFace(input, new faceapi.TinyFaceDetectorOptions({ inputSize: LIVE_INPUT_SIZE, scoreThreshold: 0.5 })).withFaceLandmarks(true);
  if (!r) return null;
  const W = input instanceof HTMLVideoElement ? input.videoWidth : input.width;
  const H = input instanceof HTMLVideoElement ? input.videoHeight : input.height;
  const b = r.detection.box;
  return {
    yaw: estimateYaw(r.landmarks.positions),
    score: r.detection.score,
    box: { x: b.x / (W || 1), y: b.y / (H || 1), width: b.width / (W || 1), height: b.height / (H || 1) },
    aligned: r.alignedRect,
  };
}

/** Gera a impressão numérica do rosto já encontrado (a parte mais pesada; feita poucas vezes). */
export async function describeFace(input: HTMLVideoElement | HTMLCanvasElement, d: LiveDetection): Promise<Descriptor | null> {
  const faceapi = await loadFaceApi();
  const [face] = await faceapi.extractFaces(input, [d.aligned as Parameters<typeof faceapi.extractFaces>[1][number]]);
  if (!face) return null;
  const desc = (await faceapi.computeFaceDescriptor(face)) as Float32Array;
  return round(desc);
}

let warming: Promise<void> | null = null;
/**
 * Prepara o reconhecimento antes de a pessoa tocar no botão: baixa os modelos e faz uma leitura
 * de aquecimento (a primeira leitura é a mais lenta, porque prepara a placa de vídeo).
 */
export function prepareFace(): Promise<void> {
  if (!warming) {
    warming = (async () => {
      const faceapi = await loadFaceApi();
      const c = document.createElement('canvas');
      c.width = 320;
      c.height = 240;
      const g = c.getContext('2d')!;
      g.fillStyle = '#888';
      g.fillRect(0, 0, c.width, c.height);
      await faceapi.detectSingleFace(c, new faceapi.TinyFaceDetectorOptions({ inputSize: LIVE_INPUT_SIZE, scoreThreshold: 0.5 })).withFaceLandmarks(true);
      const f = document.createElement('canvas');
      f.width = 150;
      f.height = 150;
      await faceapi.computeFaceDescriptor(f);
    })().catch((e) => {
      warming = null;
      throw e;
    });
  }
  return warming;
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
export const LIVENESS_YAW_RANGE = 0.2;
/** Rosto de frente: usado para gerar a impressão numérica. */
export const FRONTAL_YAW = 0.15;
