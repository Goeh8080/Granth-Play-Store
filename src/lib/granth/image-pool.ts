/**
 * Small pool of image workers (decode → downscale → JPEG) shared by the PDF
 * builder and the list thumbnails, so big page photos are never decoded at
 * full size on the main thread.
 *
 * Jobs wait in a queue and each worker gets one at a time, so the per-job
 * timeout measures real work, not time spent waiting behind other jobs.
 */
import { PAGE_MAX_EDGE, PAGE_QUALITY, prepareShot, type Shot } from "@/lib/granth/pdf-image";
import ImageWorker from "@/lib/granth/pdf-image.worker.ts?worker&inline";

type Job = {
  id: number;
  blob: Blob;
  maxEdge: number;
  quality: number;
  resolve: (shot: Shot | null | PromiseLike<Shot | null>) => void;
  timer?: number;
  worker?: Worker;
};

const JOB_TIMEOUT_MS = 20_000;

class ShotPool {
  private idle: Worker[] = [];
  private all: Worker[] = [];
  private broken = false;
  private seq = 0;
  private queue: Job[] = [];
  private running = new Map<number, Job>();

  constructor(size: number) {
    try {
      for (let index = 0; index < size; index += 1) {
        const worker = new ImageWorker();
        worker.onmessage = (event: MessageEvent<{ id: number; shot: Shot | null }>) => {
          const job = this.running.get(event.data.id);
          if (job) {
            this.running.delete(job.id);
            window.clearTimeout(job.timer);
            job.resolve(event.data.shot);
          }
          this.idle.push(worker);
          this.pump();
        };
        worker.onerror = () => {
          // e.g. a WebView that refuses blob: workers. Finish everything on the main thread.
          this.fail();
        };
        this.all.push(worker);
        this.idle.push(worker);
      }
    } catch {
      this.broken = true;
    }
    if (!this.all.length) this.broken = true;
  }

  private fail() {
    if (this.broken) return;
    this.broken = true;
    for (const worker of this.all) worker.terminate();
    const jobs = [...this.running.values(), ...this.queue];
    this.running.clear();
    this.queue = [];
    for (const job of jobs) {
      window.clearTimeout(job.timer);
      job.resolve(prepareShot(job.blob, job.maxEdge, job.quality));
    }
  }

  private pump() {
    while (!this.broken && this.idle.length && this.queue.length) {
      const worker = this.idle.pop() as Worker;
      const job = this.queue.shift() as Job;
      job.worker = worker;
      this.running.set(job.id, job);
      job.timer = window.setTimeout(() => {
        // A wedged worker must never stall a PDF or a list: do this one on the main thread
        // (the worker rejoins the pool once it answers).
        if (!this.running.delete(job.id)) return;
        job.resolve(prepareShot(job.blob, job.maxEdge, job.quality));
      }, JOB_TIMEOUT_MS);
      try {
        worker.postMessage({ id: job.id, blob: job.blob, maxEdge: job.maxEdge, quality: job.quality });
      } catch {
        this.running.delete(job.id);
        window.clearTimeout(job.timer);
        this.queue.unshift(job);
        this.fail();
        return;
      }
    }
  }

  /** Decode/downscale off the main thread; falls back to the main thread if workers are unavailable. */
  prepare(blob: Blob, maxEdge = PAGE_MAX_EDGE, quality = PAGE_QUALITY): Promise<Shot | null> {
    if (this.broken) return prepareShot(blob, maxEdge, quality);
    return new Promise<Shot | null>((resolve) => {
      this.seq += 1;
      this.queue.push({ id: this.seq, blob, maxEdge, quality, resolve });
      this.pump();
    });
  }
}

let pool: ShotPool | null = null;
export function shotPool() {
  if (!pool) {
    const cores = typeof navigator !== "undefined" ? navigator.hardwareConcurrency || 4 : 4;
    pool = new ShotPool(Math.max(1, Math.min(3, cores - 1)));
  }
  return pool;
}
