import { safeMediaPath } from "./offline-plan";

/** Only scripture image paths from the Granth API — never an open proxy. */
export const mediaPath = safeMediaPath;

const ORIGIN = "https://granth.wnmsolutions.com";

function inApk(): boolean {
  return typeof location !== "undefined" && location.protocol === "file:";
}

export function mediaUrl(path: string): string {
  if (inApk()) return `${ORIGIN}/${path}`;
  return `/api/media?src=${encodeURIComponent(path)}`;
}

export function youtubeId(raw: string | null | undefined): string | null {
  const value = (raw ?? "").trim();
  if (!value) return null;
  if (/^[\w-]{11}$/.test(value)) return value;
  const embedded = value.match(/(?:embed\/|v=|youtu\.be\/)([\w-]{11})/);
  return embedded?.[1] ?? null;
}

export function byPosition<T extends { position: string }>(rows: T[]): T[] {
  return [...rows].sort((a, b) => Number(a.position) - Number(b.position));
}

export function includesQuery(query: string, fields: Array<string | null | undefined>): boolean {
  const needle = query.trim();
  if (!needle) return true;
  return fields.some((field) => (field ?? "").includes(needle));
}
