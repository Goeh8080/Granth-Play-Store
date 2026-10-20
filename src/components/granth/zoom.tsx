import { useRef, useState, type ReactNode } from "react";

export function PinchView({ children }: { children: ReactNode }) {
  const stage = useRef<HTMLDivElement>(null);
  const view = useRef({
    scale: 1,
    x: 0,
    y: 0,
    pointers: new Map<number, { x: number; y: number }>(),
    pinch: 0,
    base: 1,
    pinching: false,
    originX: 0,
    originY: 0,
    midX: 0,
    midY: 0,
    lastX: 0,
    lastY: 0,
    panning: false,
    blockPan: false,
  });
  const [transform, setTransform] = useState("translate(0px, 0px) scale(1)");
  // Not zoomed → the browser keeps vertical panning (touch-action: pan-y), so a
  // finger on a picture scrolls the lightbox to the next picture instead of being swallowed.
  const [zoomed, setZoomed] = useState(false);
  const clamp = () => {
    const shot = view.current;
    const box = stage.current;
    if (shot.scale <= 1.02) {
      shot.scale = 1;
      shot.x = 0;
      shot.y = 0;
      return;
    }
    const width = box?.clientWidth ?? 320;
    const height = box?.clientHeight ?? 480;
    const maxX = ((shot.scale - 1) * width) / 2;
    const maxY = ((shot.scale - 1) * height) / 2;
    shot.x = Math.min(maxX, Math.max(-maxX, shot.x));
    shot.y = Math.min(maxY, Math.max(-maxY, shot.y));
  };
  const paint = () => {
    clamp();
    const shot = view.current;
    setTransform(`translate(${shot.x}px, ${shot.y}px) scale(${shot.scale})`);
    setZoomed(shot.scale > 1);
  };
  const points = () => [...view.current.pointers.values()];
  const pinchDistance = () => {
    const pts = points();
    if (pts.length < 2) return 0;
    return Math.hypot((pts[0]?.x ?? 0) - (pts[1]?.x ?? 0), (pts[0]?.y ?? 0) - (pts[1]?.y ?? 0));
  };
  const midpoint = () => {
    const pts = points();
    return {
      x: ((pts[0]?.x ?? 0) + (pts[1]?.x ?? 0)) / 2,
      y: ((pts[0]?.y ?? 0) + (pts[1]?.y ?? 0)) / 2,
    };
  };
  const center = () => {
    const shot = view.current;
    shot.scale = 1;
    shot.x = 0;
    shot.y = 0;
    shot.pinching = false;
    shot.panning = false;
    shot.blockPan = false;
    paint();
  };
  return (
    <div
      ref={stage}
      className={`zoom-stage${zoomed ? " zoomed" : ""}`}
      onPointerDown={(event) => {
        const shot = view.current;
        if (shot.pointers.size === 0) shot.blockPan = false;
        shot.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        if (shot.scale > 1 || shot.pointers.size >= 2) event.currentTarget.setPointerCapture(event.pointerId);
        shot.panning = false;
        if (shot.pointers.size >= 2) {
          shot.pinching = true;
          shot.blockPan = true;
          shot.pinch = pinchDistance();
          shot.base = shot.scale;
          const mid = midpoint();
          shot.midX = mid.x;
          shot.midY = mid.y;
          shot.originX = shot.x;
          shot.originY = shot.y;
        }
      }}
      onPointerMove={(event) => {
        const shot = view.current;
        if (!shot.pointers.has(event.pointerId)) return;
        shot.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        if (shot.pointers.size >= 2 && shot.pinch > 0) {
          const next = pinchDistance() / shot.pinch;
          const mid = midpoint();
          shot.scale = Math.min(4, Math.max(1, shot.base * next));
          if (shot.scale <= 1.05) {
            shot.scale = 1;
            shot.x = 0;
            shot.y = 0;
          } else {
            shot.x = shot.originX + (mid.x - shot.midX);
            shot.y = shot.originY + (mid.y - shot.midY);
          }
          paint();
          return;
        }
        if (shot.pinching || shot.blockPan || shot.scale <= 1) return;
        const point = shot.pointers.get(event.pointerId);
        if (!point) return;
        if (!shot.panning) {
          shot.panning = true;
          shot.lastX = point.x;
          shot.lastY = point.y;
          return;
        }
        shot.x += point.x - shot.lastX;
        shot.y += point.y - shot.lastY;
        shot.lastX = point.x;
        shot.lastY = point.y;
        paint();
      }}
      onPointerUp={(event) => {
        const shot = view.current;
        shot.pointers.delete(event.pointerId);
        shot.panning = false;
        if (shot.pointers.size < 2) {
          shot.pinching = false;
          shot.blockPan = true;
          if (shot.scale <= 1.08) center();
          else paint();
        }
      }}
      onPointerCancel={(event) => {
        const shot = view.current;
        shot.pointers.delete(event.pointerId);
        shot.pinching = false;
        shot.panning = false;
        shot.blockPan = true;
        if (shot.scale <= 1.08) center();
        else paint();
      }}
    >
      <div className="zoom-frame" style={{ transform }}>
        {children}
      </div>
    </div>
  );
}