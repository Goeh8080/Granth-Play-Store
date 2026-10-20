import { test } from "node:test";
import assert from "node:assert/strict";
import { fullyCachedGranths, granthImagePaths, imageProgressLabel, safeMediaPath } from "./offline-plan.ts";

test("safeMediaPath keeps only upstream media paths", () => {
  assert.equal(safeMediaPath("granths/a-1.jpg"), "granths/a-1.jpg");
  assert.equal(safeMediaPath("/uploads/x.png"), "uploads/x.png");
  assert.equal(safeMediaPath("https://granth.wnmsolutions.com/granths/p.jpg"), "granths/p.jpg");
  assert.equal(safeMediaPath("../etc/passwd"), null);
  assert.equal(safeMediaPath("granths/../../x"), null);
  assert.equal(safeMediaPath(""), null);
  assert.equal(safeMediaPath(null), null);
});

test("a granth is offline only when every one of its pages is stored", () => {
  const needs = granthImagePaths(
    [
      { id: "g1", imagePath: "granths/cover1.jpg" },
      { id: "g2", imagePath: null },
    ],
    [
      { granth_id: "g1", image_path: "granths/p1.jpg" },
      { granth_id: "g1", image_path: "granths/p2.jpg" },
      { granth_id: "g1", image_path: "granths/p1.jpg" },
    ],
  );
  assert.deepEqual([...(needs.get("g1") ?? [])].sort(), ["granths/cover1.jpg", "granths/p1.jpg", "granths/p2.jpg"]);
  assert.deepEqual(needs.get("g2"), []);
  assert.deepEqual(fullyCachedGranths(needs, new Set(["granths/cover1.jpg", "granths/p1.jpg"])), []);
  assert.deepEqual(fullyCachedGranths(needs, new Set(["granths/cover1.jpg", "granths/p1.jpg", "granths/p2.jpg"])), ["g1"]);
});

test("progress label never claims success for failed pages", () => {
  assert.equal(imageProgressLabel({ done: 0, failed: 0, total: 0, running: false }, false), "");
  assert.match(imageProgressLabel({ done: 3, failed: 0, total: 10, running: true }, true), /3\/10/);
  assert.match(imageProgressLabel({ done: 8, failed: 2, total: 10, running: false }, false), /^2 पेज सेव नहीं हुए/);
  assert.equal(imageProgressLabel({ done: 10, failed: 0, total: 10, running: false }, false), "सभी पेज इस डिवाइस पर सेव हैं");
});
