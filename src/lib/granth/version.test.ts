import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../../../", import.meta.url);
const read = (path: string) => readFileSync(new URL(path, root), "utf8");

test("app version is the same everywhere", () => {
  const props = read("mobile/version.properties");
  const name = /^VERSION_NAME=(.+)$/m.exec(props)?.[1]?.trim();
  const code = Number(/^VERSION_CODE=(\d+)$/m.exec(props)?.[1]);
  assert.ok(name && /^\d+\.\d+\.\d+$/.test(name), "VERSION_NAME");
  assert.ok(code >= 22, "VERSION_CODE must stay above the previously shipped 20");
  const app = JSON.parse(read("mobile/app.json")).expo;
  assert.equal(app.version, name);
  assert.equal(app.android.versionCode, code);
  assert.equal(JSON.parse(read("mobile/package.json")).version, name);
  assert.match(read("mobile/android/app/build.gradle"), /version\.properties/);
});

test("no signing secrets or keystores are tracked", () => {
  const gradle = read("mobile/android/app/build.gradle");
  assert.doesNotMatch(gradle, /storePassword\s+['"](?!android['"])/);
  const ignore = read(".gitignore");
  assert.match(ignore, /\*\.jks/);
});
