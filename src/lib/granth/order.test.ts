import { test } from "node:test";
import assert from "node:assert/strict";
import { devanagariDigits, sortPramans } from "./order.ts";
import { normalizeText, rankBySearch } from "./search.ts";

test("pramans sort by page number in Devanagari or Latin digits", () => {
  assert.equal(devanagariDigits("१२३"), "123");
  assert.deepEqual(
    sortPramans([{ title: "पृष्ठ १०" }, { title: "पृष्ठ 2" }, { title: "पृष्ठ ३" }]).map((row) => row.title),
    ["पृष्ठ 2", "पृष्ठ ३", "पृष्ठ १०"],
  );
});

test("search matches Hindi titles from a romanized query", () => {
  assert.equal(normalizeText("  कबीर   सागर "), "कबीर सागर");
  const rows = [{ t: "कबीर सागर" }, { t: "अनुराग सागर" }, { t: "ज्ञान" }];
  assert.deepEqual(rankBySearch(rows, "kabir", (row) => [row.t]).map((row) => row.t), ["कबीर सागर"]);
});
