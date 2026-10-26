import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

class Event {
  listeners = [];
  addListener(fn) { this.listeners.push(fn); }
  fire(...args) { for (const fn of this.listeners) fn(...args); }
}

async function worker(options = {}) {
  let snapshot = { deckID: "test-deck", pageID: "document-session", slideID: "id.slide1", title: "Synthetic", position: 1, total: 3 };
  const state = { sent: [], advances: 0, injections: 0, probes: 0, disconnected: false, ...options };
  const port = {
    onMessage: new Event(), onDisconnect: new Event(),
    postMessage(message) { state.sent.push(message); },
    disconnect() { state.disconnected = true; this.onDisconnect.fire(); },
  };
  const tab = { id: 42, url: "https://docs.google.com/presentation/d/test-deck/present#slide=id.slide1" };
  if (options.url) tab.url = options.url;
  const chrome = {
    runtime: { id: "extension-test", onMessage: new Event(), connectNative(name) { assert.equal(name, "com.biblejustin.localprompt.slides"); return port; } },
    scripting: { async executeScript(value) { assert.equal(value.target.tabId, 42); assert.deepEqual(value.target.frameIds, [0]); state.injections++; } },
    tabs: {
      onRemoved: new Event(), onReplaced: new Event(), onUpdated: new Event(),
      async query() { return [tab]; }, async get(id) { assert.equal(id, 42); return tab; },
      async sendMessage(id, message, target) {
        assert.equal(id, 42); assert.equal(target.frameId, 0);
        if (message.operation === "identity") {
          state.probes++;
          if (state.missingDocument) throw new Error("No receiving content script.");
          return { ok: true, contentBuild: state.contentBuild ?? "0.4.0.2", identity: { deckID: snapshot.deckID, pageID: state.documentPageID ?? snapshot.pageID } };
        }
        if (message.operation === "advance") {
          state.advances++;
          if (state.gate) await state.gate;
          if (state.failAdvance) return { ok: false, contentBuild: "0.4.0.2", error: "Synthetic failure after possible dispatch. No retry." };
          assert.equal(message.expected.pageID, snapshot.pageID);
          if (snapshot.position === snapshot.total) return { ok: true, contentBuild: "0.4.0.2", snapshot, ended: true };
          snapshot = { ...snapshot, position: snapshot.position + 1, slideID: `id.slide${snapshot.position + 1}` };
        }
        return { ok: true, contentBuild: state.contentBuild ?? "0.4.0.2", snapshot: { ...snapshot } };
      },
    },
  };
  globalThis.chrome = chrome;
  await import(`../../BrowserExtension/service-worker.js?test=${randomUUID()}`);
  const popup = (action, sender = { id: "extension-test" }) => new Promise(resolve => {
    const accepted = chrome.runtime.onMessage.listeners[0]({ channel: "localprompt-slides-v1", action }, sender, resolve);
    if (!accepted && sender.tab) resolve(null);
  });
  const settle = async () => { await new Promise(resolve => setTimeout(resolve, 0)); };
  const notifyLeaving = (message = {}, sender = {}) => chrome.runtime.onMessage.listeners[0](
    { channel: "localprompt-slides-v1", action: "page-leaving", deckID: snapshot.deckID, pageID: snapshot.pageID, ...message },
    { id: "extension-test", tab: { id: 42 }, frameId: 0, ...sender }, () => {},
  );
  const command = (requestID, operation = "advance", expected = snapshot) => {
    const session = state.sent.find(message => message.type === "hello")?.session;
    port.onMessage.fire({ v: 1, type: "command", session, requestID, operation, snapshot: { ...expected } });
  };
  return { state, port, tab, chrome, popup, settle, command, notifyLeaving, snapshot: () => ({ ...snapshot }) };
}

test("explicit popup connection sends hello for exact selected tab and no advance", async () => {
  const w = await worker();
  const status = await w.popup("connect");
  assert.equal(status.connected, true);
  assert.equal(status.connecting, false);
  assert.equal(status.connectorBuild, "0.4.0.2");
  assert.equal(status.contentBuild, "0.4.0.2");
  assert.equal(w.state.injections, 1);
  assert.equal(w.state.advances, 0);
  assert.equal(w.state.sent[0].type, "hello");
  assert.equal(w.state.sent[0].snapshot.pageID, "document-session");
});

test("native status and next request return correlated results", async () => {
  const w = await worker();
  await w.popup("connect");
  w.command(1, "status"); await w.settle();
  w.command(2); await w.settle();
  const results = w.state.sent.filter(message => message.type === "result");
  assert.deepEqual(results.map(value => value.requestID), [1, 2]);
  assert.deepEqual(results.map(value => value.snapshot.position), [1, 2]);
  assert.equal(w.state.advances, 1);
});

test("duplicate command disconnects without replaying dispatched advance", async () => {
  const w = await worker();
  await w.popup("connect");
  w.command(1); await w.settle();
  w.command(1); await w.settle();
  assert.equal(w.state.advances, 1);
  assert.equal(w.state.disconnected, true);
  assert.match(w.state.sent.find(value => value.type === "result" && value.error)?.error, /Duplicate/);
});

test("native disconnect drops queued commands even while one action is already in flight", async () => {
  let release;
  const w = await worker({ gate: new Promise(resolve => { release = resolve; }) });
  await w.popup("connect");
  w.command(1); await w.settle();
  w.command(2);
  const session = w.state.sent[0].session;
  w.port.onMessage.fire({ v: 1, type: "disconnect", session });
  release(); await w.settle();
  assert.equal(w.state.advances, 1);
  assert.equal(w.state.disconnected, true);
  assert.equal(w.state.sent.filter(message => message.type === "result").length, 0);
});

test("content failure reports error and disconnects with no retry", async () => {
  const w = await worker({ failAdvance: true });
  await w.popup("connect");
  w.command(1); await w.settle();
  assert.equal(w.state.advances, 1);
  assert.equal(w.state.disconnected, true);
  assert.match(w.state.sent.find(value => value.type === "result")?.error, /No retry/);
});

test("same-document loading, URL, and complete events keep an in-flight cue connected", async () => {
  let release;
  const w = await worker({ gate: new Promise(resolve => { release = resolve; }) });
  await w.popup("connect");
  w.command(1); await w.settle();
  w.chrome.tabs.onUpdated.fire(42, { status: "loading", url: "https://docs.google.com/presentation/d/test-deck/present#slide=id.slide2" });
  w.chrome.tabs.onUpdated.fire(42, { status: "complete" });
  await w.settle();
  assert.equal((await w.popup("status")).connected, true);
  assert.equal(w.state.probes, 2);
  release(); await w.settle();
  assert.equal(w.state.advances, 1);
  assert.equal(w.state.sent.find(message => message.type === "result")?.snapshot.position, 2);
  assert.equal(w.state.disconnected, false);
});

test("transient wrong event URL stays connected when authoritative tab and document match", async () => {
  const w = await worker();
  await w.popup("connect");
  w.chrome.tabs.onUpdated.fire(42, { url: "https://docs.google.com/presentation/d/test-deck/edit" });
  await w.settle();
  assert.equal((await w.popup("status")).connected, true);
  assert.equal(w.state.probes, 1);
});

test("authoritative navigation disconnects even when event URL appears safe; diagnostics redact deck ID", async () => {
  for (const url of [
    "https://docs.google.com/presentation/d/test-deck/edit",
    "https://docs.google.com/presentation/d/secret-private-deck/present",
    "https://example.com/presentation/d/test-deck/present",
  ]) {
    const w = await worker();
    await w.popup("connect");
    w.tab.url = url;
    w.chrome.tabs.onUpdated.fire(42, { url: "https://docs.google.com/presentation/d/test-deck/present#slide=id.slide2" });
    await w.settle();
    const state = await w.popup("status");
    assert.equal(state.connected, false);
    assert.match(state.error, /origin .*page .*deck /);
    assert.ok(!state.error.includes("secret-private-deck"));
    assert.ok(!state.error.includes("test-deck"));
    assert.equal(w.state.advances, 0);
  }
});

test("stale content build is rejected before native connection or slide control", async () => {
  const w = await worker({ contentBuild: "0.4.0.1" });
  const state = await w.popup("connect");
  assert.equal(state.ok, false);
  assert.match(state.error, /older connector.*Refresh/);
  assert.equal(w.state.sent.length, 0);
  assert.equal(w.state.advances, 0);
});

test("real reload with missed pagehide disconnects on missing or new document nonce", async () => {
  for (const changed of [{ missingDocument: true }, { documentPageID: "new-document" }]) {
    const w = await worker(changed);
    await w.popup("connect");
    w.chrome.tabs.onUpdated.fire(42, { status: "loading" });
    w.chrome.tabs.onUpdated.fire(42, { status: "complete" });
    await w.settle();
    assert.equal((await w.popup("status")).connected, false);
    assert.equal(w.state.advances, 0);
    w.command(1); await w.settle();
    assert.equal(w.state.advances, 0);
  }
});

test("only bound top-frame document can disconnect via pagehide", async () => {
  const w = await worker();
  await w.popup("connect");
  for (const [message, sender] of [
    [{}, { id: "foreign-extension" }], [{}, { tab: { id: 77 } }], [{}, { frameId: 1 }],
    [{ pageID: "old-document" }, {}], [{ deckID: "other-deck" }, {}],
  ]) {
    w.notifyLeaving(message, sender);
    assert.equal((await w.popup("status")).connected, true);
  }
  w.notifyLeaving();
  assert.equal((await w.popup("status")).connected, false);
});

test("pagehide cancels queued advances before dispatch", async () => {
  let release;
  const w = await worker({ gate: new Promise(resolve => { release = resolve; }) });
  await w.popup("connect");
  w.command(1); await w.settle();
  w.command(2);
  w.notifyLeaving();
  release(); await w.settle();
  assert.equal(w.state.advances, 1);
  assert.equal(w.state.disconnected, true);
  assert.equal(w.state.sent.filter(message => message.type === "result").length, 0);
});

test("closing another tab has no effect; closing selected tab disconnects", async () => {
  const w = await worker();
  await w.popup("connect");
  w.chrome.tabs.onRemoved.fire(77);
  assert.equal((await w.popup("status")).connected, true);
  w.chrome.tabs.onRemoved.fire(42);
  assert.equal((await w.popup("status")).connected, false);
});

test("content scripts cannot select tabs through popup messages; editor route never injected", async () => {
  const w = await worker({ url: "https://docs.google.com/presentation/d/test-deck/edit" });
  assert.equal(await w.popup("connect", { id: "extension-test", tab: { id: 42 } }), null);
  const status = await w.popup("connect");
  assert.equal(status.ok, false);
  assert.equal(w.state.injections, 0);
  assert.equal(w.state.sent.length, 0);
});
