/// <reference lib="webworker" />
import { prepareShot } from "./pdf-image";

type Job = { id: number; blob: Blob; maxEdge: number; quality: number };

const scope = self as unknown as DedicatedWorkerGlobalScope;

scope.onmessage = async (event: MessageEvent<Job>) => {
  const { id, blob, maxEdge, quality } = event.data;
  try {
    const shot = await prepareShot(blob, maxEdge, quality);
    if (shot) scope.postMessage({ id, shot }, [shot.bytes.buffer as ArrayBuffer]);
    else scope.postMessage({ id, shot: null });
  } catch (error) {
    scope.postMessage({ id, shot: null, error: error instanceof Error ? error.message : "image" });
  }
};
