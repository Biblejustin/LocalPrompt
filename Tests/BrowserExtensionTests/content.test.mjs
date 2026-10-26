import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { randomUUID } from "node:crypto";

const source = await readFile(new URL("../../BrowserExtension/content.js", import.meta.url), "utf8");

function slideshow(options = {}) {
  const state = {
    position: 1, total: 3, initialized: true, actions: [], pickerActions: 0,
    selected: 1, blank: false, captionCount: 1, notifications: [], ...options,
  };
  const location = { href: `https://docs.google.com/presentation/d/test-deck/present#slide=id.slide${state.position}` };
  if (options.url) location.href = options.url;
  const observers = new Set();
  const events = new Map();
  const mutate = () => { for (const callback of [...observers]) callback(); };
  const setSlideID = position => { location.href = `https://docs.google.com/presentation/d/test-deck/present#slide=id.slide${position}`; mutate(); };
  const caption = { getAttribute: name => String(name === "aria-posinset" ? state.position : state.total) };
  const picker = { dispatchEvent(event) { if (event.type === "mouseup") { state.pickerActions++; state.initialized = true; mutate(); } } };
  const items = Array.from({ length: state.total }, (_, index) => ({
    getAttribute: name => name === "aria-checked" && state.selected === index + 1 ? "true" : "false",
    dispatchEvent(event) {
      if (event.type !== "mouseup") return;
      state.actions.push(index + 1);
      if (state.ignoreActions) return;
      state.position = index + 1 + (state.unexpectedJump ? 1 : 0);
      state.selected = state.position;
      if (state.delayURL) { mutate(); setTimeout(() => setSlideID(state.position), 10); }
      else setSlideID(state.position);
    },
  }));
  const document = {
    title: "Synthetic cue test", documentElement: {},
    querySelectorAll(selector) {
      if (selector.includes('aria-selected="true"')) return Array(state.captionCount).fill(caption);
      if (selector.includes("menuitemradio")) return state.initialized ? items : [];
      if (selector.includes("interruption")) return state.blank ? [{ checkVisibility: () => true }] : [];
      if (selector.includes('role="listbox"')) return [picker];
      throw new Error(`Unexpected selector: ${selector}`);
    },
  };
  let listener;
  const context = vm.createContext({
    document, location, URL, URLSearchParams, crypto: { randomUUID }, console,
    setTimeout: (fn, delay) => setTimeout(fn, Math.min(delay, 70)), clearTimeout,
    window: { addEventListener: (name, fn) => events.set(name, fn), removeEventListener: name => events.delete(name) },
    MouseEvent: class { constructor(type, values) { Object.assign(this, { type }, values); } },
    MutationObserver: class { constructor(callback) { this.callback = callback; } observe() { observers.add(this.callback); } disconnect() { observers.delete(this.callback); } },
    chrome: { runtime: {
      id: "extension-test", onMessage: { addListener(value) { listener = value; } },
      sendMessage(message) { state.notifications.push(message); return Promise.resolve(); },
    } },
  });
  vm.runInContext(source, context);
  function send(operation, expected, senderID = "extension-test") {
    return new Promise(resolve => {
      const accepted = listener({ channel: "localprompt-slides-v1", operation, expected }, { id: senderID }, value => resolve(JSON.parse(JSON.stringify(value))));
      if (!accepted) resolve(null);
    });
  }
  const event = (name, detail = {}) => events.get(name)?.(detail);
  return { state, location, send, context, source, mutate, setSlideID, event };
}

test("status initializes lazy picker without moving slides", async () => {
  const page = slideshow({ initialized: false });
  const result = await page.send("status");
  assert.equal(result.ok, true);
  assert.equal(result.contentBuild, "0.4.0.2");
  assert.equal(result.snapshot.position, 1);
  assert.equal(page.state.pickerActions, 2);
  assert.deepEqual(page.state.actions, []);
});

test("exact next slide selects one menu entry and duplicate expected snapshot cannot replay", async () => {
  const page = slideshow();
  const initial = (await page.send("status")).snapshot;
  const next = await page.send("advance", initial);
  assert.equal(next.ok, true);
  assert.equal(next.snapshot.position, 2);
  assert.equal(next.snapshot.slideID, "id.slide2");
  const duplicate = await page.send("advance", initial);
  assert.equal(duplicate.ok, false);
  assert.match(duplicate.error, /position changed/);
  assert.deepEqual(page.state.actions, [2]);
});

test("final slide remains visible without any mouse event", async () => {
  const page = slideshow({ position: 3, selected: 3 });
  const initial = (await page.send("status")).snapshot;
  const result = await page.send("advance", initial);
  assert.equal(result.ended, true);
  assert.equal(result.snapshot.position, 3);
  assert.deepEqual(page.state.actions, []);
});

test("manual navigation, different deck, and different document cannot receive stale cue", async () => {
  for (const change of [
    snapshot => ({ ...snapshot, position: 2 }),
    snapshot => ({ ...snapshot, deckID: "another-deck" }),
    snapshot => ({ ...snapshot, pageID: "another-document" }),
    snapshot => ({ ...snapshot, slideID: "id.different" }),
  ]) {
    const page = slideshow();
    const initial = (await page.send("status")).snapshot;
    assert.equal((await page.send("advance", change(initial))).ok, false);
    assert.deepEqual(page.state.actions, []);
  }
});

test("editor, unrelated origin, missing slide identifier, blank screen and ambiguous controls fail closed", async () => {
  for (const options of [
    { url: "https://docs.google.com/presentation/d/test-deck/edit#slide=id.slide1" },
    { url: "https://example.com/presentation/d/test-deck/present#slide=id.slide1" },
    { url: "https://docs.google.com/presentation/d/test-deck/present" },
    { blank: true }, { captionCount: 2 }, { position: 0 }, { total: 10001 },
  ]) {
    const page = slideshow(options);
    const result = await page.send("status");
    assert.equal(result.ok, false);
    assert.deepEqual(page.state.actions, []);
  }
});

test("waits for delayed URL update instead of returning stale slide ID", async () => {
  const page = slideshow({ delayURL: true });
  const result = await page.send("advance", (await page.send("status")).snapshot);
  assert.equal(result.ok, true);
  assert.equal(result.snapshot.slideID, "id.slide2");
});

test("unconfirmed or unexpected movement fails without retry", async () => {
  for (const options of [{ ignoreActions: true }, { unexpectedJump: true }]) {
    const page = slideshow(options);
    const result = await page.send("advance", (await page.send("status")).snapshot);
    assert.equal(result.ok, false);
    assert.match(result.error, /no retry/);
    assert.deepEqual(page.state.actions, [2]);
  }
});

test("overlapping request cannot dispatch another action", async () => {
  const page = slideshow({ delayURL: true });
  const initial = (await page.send("status")).snapshot;
  const first = page.send("advance", initial);
  const second = await page.send("advance", initial);
  assert.equal(second.ok, false);
  assert.match(second.error, /already in progress/);
  assert.equal((await first).ok, true);
  assert.deepEqual(page.state.actions, [2]);
});

test("reinjection preserves document identity; foreign extension messages ignored", async () => {
  const page = slideshow();
  const first = (await page.send("status")).snapshot;
  vm.runInContext(source, page.context);
  assert.equal((await page.send("status")).snapshot.pageID, first.pageID);
  assert.equal(await page.send("advance", first, "foreign-extension"), null);
  assert.deepEqual(page.state.actions, []);
});

test("identity probe works during an in-flight cue without reading transient controls", async () => {
  const page = slideshow({ delayURL: true });
  const initial = (await page.send("status")).snapshot;
  const advance = page.send("advance", initial);
  const result = await page.send("identity");
  assert.equal(result.ok, true);
  assert.deepEqual(result.identity, { pageID: initial.pageID, deckID: initial.deckID });
  assert.equal((await advance).ok, true);
  page.state.captionCount = 0;
  assert.equal((await page.send("identity")).ok, true);
  assert.deepEqual(page.state.actions, [2]);
});

test("pagehide notifies bound document identity and prevents pending slide dispatch", async () => {
  const page = slideshow();
  const initial = (await page.send("status")).snapshot;
  const advance = page.send("advance", initial);
  page.event("pagehide");
  const result = await advance;
  assert.equal(result.ok, false);
  assert.match(result.error, /leaving/);
  assert.deepEqual(page.state.actions, []);
  assert.equal(page.state.notifications.length, 1);
  assert.equal(page.state.notifications[0].action, "page-leaving");
  assert.equal(page.state.notifications[0].pageID, initial.pageID);
  assert.equal((await page.send("identity")).ok, false);
  page.event("pageshow", { persisted: true, isTrusted: false });
  assert.equal((await page.send("status")).ok, false);
  page.event("pageshow", { persisted: true, isTrusted: true });
  const restored = await page.send("status");
  assert.equal(restored.ok, true);
  assert.notEqual(restored.snapshot.pageID, initial.pageID);
  assert.equal((await page.send("advance", initial)).ok, false);
  assert.deepEqual(page.state.actions, []);
});
