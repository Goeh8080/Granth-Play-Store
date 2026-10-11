import { useRef, useState, type ReactNode } from "react";

export function PinchView({ children }: { children: ReactNode }) {
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
  });
  const [transform, setTransform] = useState("translate(0px, 0px) scale(1)");
  const paint = () => {
    const shot = view.current;
    setTransform(`translate(${shot.x}px, ${shot.y}px) scale(${shot.scale})`);
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
  return (
    <div
      className="zoom-stage"
      onPointerDown={(event) => {
        const shot = view.current;
        shot.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        event.currentTarget.setPointerCapture(event.pointerId);
        shot.panning = false;
        if (shot.pointers.size >= 2) {
          shot.pinching = true;
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
          shot.scale = Math.min(5, Math.max(1, shot.base * next));
          if (shot.scale <= 1.02) {
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
        if (shot.pinching || shot.scale <= 1) return;
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
        shot.pinching = shot.pointers.size >= 2;
        shot.panning = false;
      }}
      onPointerCancel={(event) => {
        const shot = view.current;
        shot.pointers.delete(event.pointerId);
        shot.pinching = false;
        shot.panning = false;
      }}
    >
      <div className="zoom-frame" style={{ transform }}>
        {children}
      </div>
    </div>
  );
}
