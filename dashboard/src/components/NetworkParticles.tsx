"use client";

import { useEffect, useRef } from "react";

interface Node {
  x: number;
  y: number;
  vx: number;
  vy: number;
  r: number;
  o: number;
}

export default function NetworkParticles() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const ctx = c.getContext("2d");
    if (!ctx) return;

    let id: number;
    const nodes: Node[] = [];
    const N = 40;
    const LINK = 150;

    function size() {
      c!.width = window.innerWidth;
      c!.height = window.innerHeight;
    }

    function seed() {
      size();
      nodes.length = 0;
      for (let i = 0; i < N; i++) {
        nodes.push({
          x: Math.random() * c!.width,
          y: Math.random() * c!.height,
          vx: (Math.random() - 0.5) * 0.3,
          vy: (Math.random() - 0.5) * 0.3,
          r: Math.random() * 1.8 + 0.6,
          o: Math.random() * 0.3 + 0.06,
        });
      }
    }

    function frame() {
      ctx!.clearRect(0, 0, c!.width, c!.height);

      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i];
        a.x += a.vx;
        a.y += a.vy;
        if (a.x < 0 || a.x > c!.width) a.vx *= -1;
        if (a.y < 0 || a.y > c!.height) a.vy *= -1;

        for (let j = i + 1; j < nodes.length; j++) {
          const b = nodes[j];
          const dx = a.x - b.x;
          const dy = a.y - b.y;
          const d = Math.sqrt(dx * dx + dy * dy);
          if (d < LINK) {
            const alpha = (1 - d / LINK) * 0.08;
            ctx!.strokeStyle = `rgba(0, 255, 204, ${alpha})`;
            ctx!.lineWidth = 0.5;
            ctx!.beginPath();
            ctx!.moveTo(a.x, a.y);
            ctx!.lineTo(b.x, b.y);
            ctx!.stroke();
          }
        }

        ctx!.beginPath();
        ctx!.arc(a.x, a.y, a.r, 0, 6.283);
        ctx!.fillStyle = `rgba(0, 255, 204, ${a.o})`;
        ctx!.fill();
      }

      id = requestAnimationFrame(frame);
    }

    seed();
    frame();
    window.addEventListener("resize", size);
    return () => {
      cancelAnimationFrame(id);
      window.removeEventListener("resize", size);
    };
  }, []);

  return (
    <canvas
      ref={ref}
      className="fixed inset-0 pointer-events-none"
      style={{ zIndex: 0 }}
    />
  );
}
