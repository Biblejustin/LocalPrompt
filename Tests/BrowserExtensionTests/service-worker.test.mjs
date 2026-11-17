import test, { afterEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

class Event {
  listeners = [];
  addListener(fn) { this.listeners.push(fn); }
  fire(...args) { for (const fn of this.listeners) fn(...args); }
}

const cleanups = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });

async function worker(options = {}) {
  let snapshot = { deckID: "test-deck", pageID: "document-session", slideID: "id.slide1", title: "Synthetic", position: 1, total: 3 };
  const state = { sent: [], updates: [], jumps: [], advances: 0, injections: 0, probes: 0, readyProbes: 0, disconnected: false, ...options };
  const port = {
    onMessage: new Event(), onDisconnect: new Event(),
    postMessage(message) { state.sent.push(message); },
    disconnect() { state.disconnected = true; this.onDisconnect.fire(); },
  };
  const tab = { id: 42, status: options.loading ? "loading" : "complete", url: "https://docs.google.com/presentation/d/test-deck/present#slide=id.slide1" };
  if (options.url) tab.url = options.url;
  const chrome = {
    runtime: { id: "extension-test", onMessage: new Event(), connectNative(name) { assert.equal(name, "com.biblejustin.localprompt.slides"); return port; } },
    scripting: { async executeScript(value) { assert.equal(value.target.tabId, 42); assert.deepEqual(value.target.frameIds, [0]); assert.match(tab.url, /\/present/); state.injections++; if (state.injectionGate) await state.injectionGate; } },
    tabs: {
      onRemoved: new Event(), onReplaced: new Event(), onUpdated: new Event(),
      async query() { return [tab]; }, async get(id) { assert.equal(id, 42); return tab; },
      async update(id, value) {
        assert.equal(id, 42); state.updates.push(value);
        if (state.navigationGate) await state.navigationGate;
        tab.url = value.url;
        if (!state.loading) tab.status = "complete";
        return tab;
      },
      async sendMessage(id, message, target) {
        assert.equal(id, 42); assert.equal(target.frameId, 0);
        if (message.operation === "ready") {
          state.readyProbes++;
          return { ok: true, contentBuild: state.contentBuild ?? "0.5.5", ready: state.ready !== false };
        }
        if (message.operation === "identity") {
          state.probes++;
          if (state.missingDocument) throw new Error("No receiving content script.");
          return { ok: true, contentBuild: state.contentBuild ?? "0.5.5", identity: { deckID: snapshot.deckID, pageID: state.documentPageID ?? snapshot.pageID } };
        }
        if (message.operation === "advance") {
          state.advances++;
          if (state.gate) await state.gate;
          if (state.failAdvance) return { ok: false, contentBuild: "0.5.5", error: "Synthetic failure after possible dispatch. No retry." };
          assert.equal(message.expected.pageID, snapshot.pageID);
          if (snapshot.position === snapshot.total) return { ok: true, contentBuild: "0.5.5", snapshot, ended: true };
          snapshot = { ...snapshot, position: snapshot.position + 1, slideID: `id.slide${snapshot.position + 1}` };
        }
        if (message.operation === "goToSlide") {
          state.jumps.push(message.targetPosition);
          assert.deepEqual(message.expected, snapshot);
          if (state.gate) await state.gate;
          if (state.failJump) return { ok: false, contentBuild: "0.5.5", error: "Unconfirmed jump. No retry." };
          snapshot = { ...snapshot, position: message.targetPosition, slideID: `id.slide${message.targetPosition}` };
        }
        return { ok: true, contentBuild: state.contentBuild ?? "0.5.5", snapshot: { ...snapshot } };
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
  const command = (requestID, operation = "advance", expected = snapshot, fields = {}) => {
    const session = state.sent.find(message => message.type === "hello")?.session;
    port.onMessage.fire({ v: 1, type: "command", session, requestID, operation, snapshot: { ...expected }, ...fields });
  };
  cleanups.push(() => popup("disconnect"));
  return { state, port, tab, chrome, popup, settle, command, notifyLeaving, snapshot: () => ({ ...snapshot }) };
}

test("explicit popup connection sends hello for exact selected tab and no advance", async () => {
  const w = await worker();
  const status = await w.popup("connect");
  assert.equal(status.connected, true);
  assert.equal(status.connecting, true);
  assert.equal(status.paired, false);
  assert.equal(status.connectorBuild, "0.5.5");
  assert.equal(status.contentBuild, "0.5.5");
  assert.equal(w.state.injections, 1);
  assert.equal(w.state.advances, 0);
  assert.deepEqual(w.state.jumps, []);
  assert.equal(w.state.sent[0].type, "hello");
  assert.equal(w.state.sent[0].snapshot.pageID, "document-session");
  w.command(1, "status"); await w.settle();
  assert.equal((await w.popup("status")).paired, true);
  assert.equal((await w.popup("status")).connecting, false);
});

test("direct jump forwards bounded target and correlates forward, backward and same-slide responses", async () => {
  const w = await worker();
  await w.popup("connect");
  for (const [requestID, targetPosition] of [[1, 3], [2, 1], [3, 1]]) {
    w.command(requestID, "goToSlide", w.snapshot(), { targetPosition });
    await w.settle();
  }
  assert.deepEqual(w.state.jumps, [3, 1, 1]);
  assert.equal(w.state.advances, 0);
  const responses = w.state.sent.filter(message => message.type === "result");
  assert.deepEqual(responses.map(message => message.snapshot.position), [3, 1, 1]);
  assert.deepEqual(responses.map(message => message.requestID), [1, 2, 3]);
});

test("invalid native jump targets and unexpected target fields fail before content dispatch", async () => {
  for (const [operation, targetPosition] of [["goToSlide", 0], ["goToSlide", 4], ["goToSlide", "2"], ["advance", 2], ["status", 2]]) {
    const w = await worker();
    await w.popup("connect");
    w.command(1, operation, w.snapshot(), { targetPosition }); await w.settle();
    assert.equal(w.state.disconnected, true);
    assert.equal(w.state.advances, 0);
    assert.deepEqual(w.state.jumps, []);
  }
});

test("duplicate or unconfirmed direct jumps never replay", async () => {
  for (const failJump of [false, true]) {
    const w = await worker({ failJump });
    await w.popup("connect");
    const expected = w.snapshot();
    w.command(1, "goToSlide", expected, { targetPosition: 3 }); await w.settle();
    w.command(1, "goToSlide", expected, { targetPosition: 3 }); await w.settle();
    assert.deepEqual(w.state.jumps, [3]);
    assert.equal(w.state.advances, 0);
    assert.equal(w.state.disconnected, true);
  }
});

test("pagehide cancels queued direct jumps after one request has dispatched", async () => {
  let release;
  const w = await worker({ gate: new Promise(resolve => { release = resolve; }) });
  await w.popup("connect");
  w.command(1, "goToSlide", w.snapshot(), { targetPosition: 3 }); await w.settle();
  w.command(2, "goToSlide", w.snapshot(), { targetPosition: 2 });
  w.notifyLeaving(); release(); await w.settle();
  assert.deepEqual(w.state.jumps, [3]);
  assert.equal(w.state.sent.filter(message => message.type === "result").length, 0);
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

test("only popup converts editor to standalone slideshow before injection", async () => {
  const w = await worker({ url: "https://docs.google.com/presentation/d/test-deck/edit" });
  assert.equal(await w.popup("connect", { id: "extension-test", tab: { id: 42 } }), null);
  const status = await w.popup("connect");
  assert.equal(status.ok, true);
  assert.deepEqual(w.state.updates, [{ url: "https://docs.google.com/presentation/d/test-deck/present" }]);
  assert.equal(w.state.injections, 1);
  assert.equal(w.state.sent[0].type, "hello");
  assert.equal(w.state.advances, 0);
});

test("loading and late slideshow controls are awaited without sending native hello early", async () => {
  const w = await worker({ loading: true, ready: false });
  const pending = w.popup("connect");
  await w.settle();
  assert.equal((await w.popup("status")).connecting, true);
  assert.equal(w.state.injections, 0);
  w.tab.status = "complete";
  await new Promise(resolve => setTimeout(resolve, 180));
  assert.equal(w.state.injections, 1);
  assert.equal(w.state.sent.length, 0);
  w.state.ready = true;
  assert.equal((await pending).ok, true);
  assert.equal(w.state.injections, 1);
  assert.equal(w.state.advances, 0);
});

test("cancel and tab close prevent pending injection from opening a native connection", async () => {
  for (const cancel of [w => w.popup("disconnect"), w => w.chrome.tabs.onRemoved.fire(42)]) {
    let release;
    const w = await worker({ injectionGate: new Promise(resolve => { release = resolve; }) });
    const pending = w.popup("connect");
    await w.settle();
    await cancel(w);
    release();
    assert.equal((await pending).ok, false);
    assert.equal((await w.popup("status")).connected, false);
    assert.equal(w.state.sent.length, 0);
  }
});

test("navigation away during startup cancels pairing and never selects a different deck", async () => {
  let release;
  const w = await worker({ injectionGate: new Promise(resolve => { release = resolve; }) });
  const pending = w.popup("connect");
  await w.settle();
  w.tab.url = "https://docs.google.com/presentation/d/other-deck/present";
  w.chrome.tabs.onUpdated.fire(42, { status: "complete" });
  await w.settle();
  release();
  assert.equal((await pending).ok, false);
  assert.equal(w.state.sent.length, 0);
  assert.equal(w.state.advances, 0);
});

test("canceled old request cannot disconnect a newer explicit connection", async () => {
  let release;
  const w = await worker({ injectionGate: new Promise(resolve => { release = resolve; }) });
  const old = w.popup("connect");
  await w.settle();
  await w.popup("disconnect");
  w.state.injectionGate = null;
  assert.equal((await w.popup("connect")).ok, true);
  release();
  assert.equal((await old).ok, false);
  assert.equal((await w.popup("status")).connected, true);
  assert.equal(w.state.sent.filter(message => message.type === "hello").length, 1);
});
