import { X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { PDF_STYLES, rememberPdfStyle, savedPdfStyle, type PdfStyle } from "@/lib/granth/pdf-style";

export const APP_VERSION = "1.0.1";

export type UiLook = "classic" | "combo" | "glass" | "neu" | "clay" | "material" | "flat" | "bento";

const LOOKS: Array<{ id: UiLook; title: string }> = [
  { id: "combo", title: "Bento + Clay" },
  { id: "classic", title: "सादा" },
  { id: "glass", title: "Glassmorphism" },
  { id: "neu", title: "Neumorphism" },
  { id: "clay", title: "Claymorphism" },
  { id: "material", title: "Material" },
  { id: "flat", title: "Flat" },
  { id: "bento", title: "Bento" },
];

export function applySavedLook() {
  const root = document.documentElement;
  root.classList.remove("theme-dark", "ui-glass", "ui-neu", "ui-clay", "ui-material", "ui-flat", "ui-bento", "ui-combo");
  const look = localStorage.getItem("granth-look") || "classic";
  if (look !== "classic") root.classList.add(look === "combo" ? "ui-combo" : `ui-${look}`);
}

function rememberLayout(cols: 1 | 2) {
  localStorage.setItem("ui-cols", String(cols));
  localStorage.setItem("topic-cols", String(cols));
  localStorage.setItem("granth-cols", String(cols));
  localStorage.setItem("praman-cols", String(cols));
  localStorage.setItem("gallery-cols", String(cols));
  window.dispatchEvent(new Event("granth-layout"));
}

export function SettingsSheet({ onClose }: { onClose: () => void }) {
  const [look, setLook] = useState<UiLook>((localStorage.getItem("granth-look") as UiLook) || "classic");
  const [cols, setCols] = useState<1 | 2>(Number(localStorage.getItem("ui-cols")) === 1 ? 1 : 2);
  const [pdf, setPdf] = useState<PdfStyle>(savedPdfStyle());
  const [secret, setSecret] = useState(false);
  const taps = useRef(0);
  useEffect(() => {
    applySavedLook();
  }, [look, secret]);
  return (
    <div className="pdf-pop" role="presentation" onClick={onClose}>
      <div className="pdf-sheet settings-sheet" role="dialog" aria-modal="true" aria-label="सेटिंग" onClick={(event) => event.stopPropagation()}>
        <div className="pdf-sheet-head">
          <h3>सेटिंग</h3>
          <button type="button" className="pill" onClick={onClose}>
            <X /> पीछे
          </button>
        </div>
        <section className="set-block">
          <h4>PDF सेटिंग</h4>
          <div className="set-picks">
            {PDF_STYLES.map((style) => (
              <button
                key={style.id}
                type="button"
                className={`pill ${pdf === style.id ? "pill-maroon" : ""}`}
                onClick={() => {
                  setPdf(style.id);
                  rememberPdfStyle(style.id);
                }}
              >
                {style.title}
              </button>
            ))}
          </div>
        </section>
        <section className="set-block">
          <h4>लेआउट</h4>
          <div className="set-picks">
            {([1, 2] as const).map((size) => (
              <button
                key={size}
                type="button"
                className={`pill ${cols === size ? "pill-maroon" : ""}`}
                onClick={() => {
                  setCols(size);
                  rememberLayout(size);
                }}
              >
                {size}×{size}
              </button>
            ))}
          </div>
        </section>
        <button
          type="button"
          className="fine version-tap"
          onClick={() => {
            taps.current += 1;
            if (taps.current >= 5) setSecret(true);
          }}
        >
          Version {APP_VERSION}
        </button>
        {secret ? (
          <section className="set-block">
            <h4>कार्ड स्टाइल</h4>
            <div className="set-picks">
              {LOOKS.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  className={`pill ${look === item.id ? "pill-maroon" : ""}`}
                  onClick={() => {
                    setLook(item.id);
                    localStorage.setItem("granth-look", item.id);
                  }}
                >
                  {item.title}
                </button>
              ))}
            </div>
          </section>
        ) : null}
      </div>
    </div>
  );
}
