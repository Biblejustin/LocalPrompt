import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { presentationID, validSnapshot, validateCommand } from "../../BrowserExtension/protocol.js";

const snapshot = { deckID: "test-deck", pageID: "document-session", slideID: "id.slide1", title: "Synthetic", position: 1, total: 3 };

test("only authenticated Google Slides presentation route is selectable", () => {
  assert.equal(presentationID("https://docs.google.com/presentation/d/test-deck/present#slide=id.slide1"), "test-deck");
  for (const url of ["https://docs.google.com/presentation/d/test-deck/edit", "https://docs.google.com/presentation/d/test-deck/preview", "https://docs.google.com/presentation/d/e/test/pub", "http://docs.google.com/presentation/d/test/present", "https://docs.google.com.evil.test/presentation/d/test/present", "https://docs.google.com:8443/presentation/d/test/present", "invalid"]) {
    assert.equal(presentationID(url), null);
  }
});

test("snapshots require verified identity and bounded integral position", () => {
  assert.equal(validSnapshot(snapshot), true);
  for (const patch of [{ slideID: "" }, { pageID: "" }, { deckID: "bad/deck" }, { position: 0 }, { position: 1.5 }, { position: 4 }, { total: 10001 }, { title: "x".repeat(257) }]) {
    assert.equal(Boolean(validSnapshot({ ...snapshot, ...patch })), false);
  }
});

test("commands require session and monotonic request IDs, and advance snapshot", () => {
  const connection = { session: "session", lastRequestID: 3 };
  const command = { v: 1, type: "command", session: "session", requestID: 4, operation: "advance", snapshot };
  assert.doesNotThrow(() => validateCommand(command, connection));
  assert.doesNotThrow(() => validateCommand({ ...command, operation: "status", snapshot: undefined }, connection));
  for (const patch of [{ v: 2 }, { session: "old-session" }, { requestID: 3 }, { requestID: 2 }, { requestID: 4.5 }, { operation: "execute" }, { snapshot: undefined }]) {
    assert.throws(() => validateCommand({ ...command, ...patch }, connection));
  }
});

test("manifest uses temporary tab access, native messaging, and fixed public extension identity", async () => {
  const manifest = JSON.parse(await readFile(new URL("../../BrowserExtension/manifest.json", import.meta.url), "utf8"));
  assert.deepEqual(manifest.permissions, ["activeTab", "scripting", "nativeMessaging"]);
  assert.equal(manifest.version, "0.4.0.2");
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.externally_connectable, undefined);
  assert.ok(manifest.key);
  const digest = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32);
  const extensionID = [...digest].map(value => String.fromCharCode("a".charCodeAt(0) + parseInt(value, 16))).join("");
  assert.equal(extensionID, "ojnmagbchlkpiajkkpkchacbbmnpmlid");
});
