import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { presentationID, slideshowSelection, validSnapshot, validateCommand } from "../../BrowserExtension/protocol.js";

const snapshot = { deckID: "test-deck", pageID: "document-session", slideID: "id.slide1", title: "Synthetic", position: 1, total: 3 };

test("only authenticated Google Slides presentation route is selectable", () => {
  assert.equal(presentationID("https://docs.google.com/presentation/d/test-deck/present#slide=id.slide1"), "test-deck");
  for (const url of ["https://docs.google.com/presentation/d/test-deck/edit", "https://docs.google.com/presentation/d/test-deck/preview", "https://docs.google.com/presentation/d/e/test/pub", "http://docs.google.com/presentation/d/test/present", "https://docs.google.com.evil.test/presentation/d/test/present", "https://docs.google.com:8443/presentation/d/test/present", "invalid"]) {
    assert.equal(presentationID(url), null);
  }
});

test("editor selection creates a clean standalone URL using current hash slide", () => {
  assert.deepEqual(slideshowSelection("https://docs.google.com/presentation/d/test-deck/edit?slide=id.old&token=private&authuser=4#slide=id.current"), {
    deckID: "test-deck", route: "edit", url: "https://docs.google.com/presentation/d/test-deck/present?slide=id.current",
  });
  assert.equal(slideshowSelection("https://docs.google.com/presentation/d/test-deck/edit?slide=id.query").url,
    "https://docs.google.com/presentation/d/test-deck/present?slide=id.query");
  assert.equal(slideshowSelection("https://docs.google.com/presentation/d/test-deck/edit#slide=javascript:bad").url,
    "https://docs.google.com/presentation/d/test-deck/present");
  for (const value of ["https://docs.google.com/presentation/d/test-deck/localpresent?token=private", "https://docs.google.com/presentation/d/test-deck/preview", "https://docs.google.com/presentation/d/test-deck/present/extra", "https://docs.google.com.evil.test/presentation/d/test-deck/edit", "https://user:password@docs.google.com/presentation/d/test-deck/edit", "http://docs.google.com/presentation/d/test-deck/edit", "about:blank"]) {
    assert.equal(slideshowSelection(value), null);
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

test("direct jump requires expected snapshot and bounded target; other commands reject target field", () => {
  const connection = { session: "session", lastRequestID: 3 };
  const command = { v: 1, type: "command", session: "session", requestID: 4, operation: "goToSlide", snapshot, targetPosition: 3 };
  for (const targetPosition of [1, 2, 3]) assert.doesNotThrow(() => validateCommand({ ...command, targetPosition }, connection));
  for (const targetPosition of [undefined, null, 0, -1, 4, 1.5, "2", NaN, Infinity]) {
    assert.throws(() => validateCommand({ ...command, targetPosition }, connection), /target slide/);
  }
  assert.throws(() => validateCommand({ ...command, snapshot: undefined }, connection), /expected slide/);
  for (const operation of ["status", "advance"]) {
    assert.throws(() => validateCommand({ ...command, operation }, connection), /Unexpected target/);
    assert.throws(() => validateCommand({ ...command, operation, targetPosition: undefined }, connection), /Unexpected target/);
  }
});

test("manifest uses temporary tab access, native messaging, and fixed public extension identity", async () => {
  const manifest = JSON.parse(await readFile(new URL("../../BrowserExtension/manifest.json", import.meta.url), "utf8"));
  assert.deepEqual(manifest.permissions, ["activeTab", "scripting", "nativeMessaging"]);
  assert.equal(manifest.version, "0.5.5");
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.externally_connectable, undefined);
  assert.ok(manifest.key);
  const digest = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32);
  const extensionID = [...digest].map(value => String.fromCharCode("a".charCodeAt(0) + parseInt(value, 16))).join("");
  assert.equal(extensionID, "ojnmagbchlkpiajkkpkchacbbmnpmlid");
});
