import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { randomUUID } from "node:crypto";

const source = await readFile(new URL("../../BrowserExtension/content.js", import.meta.url), "utf8");

function slideshow(options = {}) {
  const state = {
    position: 1, total: 3, initialized: true, actions: [], pickerActions: 0,
    selected: 1, blank: false, captionCount: 1, readyState: "complete", notifications: [], ...options,
  };
  const location = { href: `https://docs.google.com/presentation/d/test-deck/present#slide=id.slide${state.position}` };
  if (options.url) location.href = options.url;
  const observers = new Set();
  const events = new Map();
  const timers = new Set();
  const polls = new Set();
  const mutate = () => { for (const callback of [...observers]) callback(); };
  const setSlideID = (position, notify = true) => {
    location.href = `https://docs.google.com/presentation/d/test-deck/present?slide=id.slide${position}`;
    if (notify) mutate();
  };
  const caption = { getAttribute: name => String(name === "aria-posinset" ? state.position : state.total) };
  const picker = { dispatchEvent(event) { if (event.type === "mouseup") { state.pickerActions++; state.initialized = true; mutate(); } } };
  const items = Array.from({ length: state.total }, (_, index) => ({
    getAttribute: name => name === "aria-checked" && state.selected === index + 1 ? "true" : "false",
    dispatchEvent(event) {
      if (event.type !== "mouseup") return;
      state.actions.push(index + 1);
      if (state.ignoreActions) return;
      if (state.onSelect) { state.onSelect(index + 1); return; }
      state.position = index + 1 + (state.unexpectedJump ? 1 : 0);
      state.selected = state.position;
      if (state.delayURL) { mutate(); setTimeout(() => setSlideID(state.position, !state.quietURL), 10); }
      else setSlideID(state.position);
    },
  }));
  const document = {
    title: "Synthetic cue test", documentElement: {},
    get readyState() { return state.readyState; },
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
    setTimeout(fn, delay) {
      const timer = setTimeout(() => { timers.delete(timer); fn(); }, Math.min(delay, 70));
      timers.add(timer);
      return timer;
    },
    clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); },
    setInterval(fn, delay) {
      const poll = setInterval(fn, Math.min(delay, 15));
      polls.add(poll);
      return poll;
    },
    clearInterval(poll) { polls.delete(poll); clearInterval(poll); },
    window: { addEventListener: (name, fn) => events.set(name, fn), removeEventListener: name => events.delete(name) },
    MouseEvent: class { constructor(type, values) { Object.assign(this, { type }, values); } },
    MutationObserver: class { constructor(callback) { this.callback = callback; } observe() { observers.add(this.callback); } disconnect() { observers.delete(this.callback); } },
    chrome: { runtime: {
      id: "extension-test", onMessage: { addListener(value) { listener = value; } },
      sendMessage(message) { state.notifications.push(message); return Promise.resolve(); },
    } },
  });
  vm.runInContext(source, context);
  function send(operation, expected, senderID = "extension-test", fields = {}) {
    return new Promise(resolve => {
      const accepted = listener({ channel: "localprompt-slides-v1", operation, expected, ...fields }, { id: senderID }, value => resolve(JSON.parse(JSON.stringify(value))));
      if (!accepted) resolve(null);
    });
  }
  const jump = (targetPosition, expected) => send("goToSlide", expected, "extension-test", { targetPosition });
  const event = (name, detail = {}) => events.get(name)?.(detail);
  const pendingChecks = () => timers.size + polls.size + observers.size + Number(events.has("hashchange"));
  return { state, location, send, jump, context, source, mutate, setSlideID, event, pendingChecks };
}

test("direct jump selects requested slide once, forwards and backwards", async () => {
  const page = slideshow({ total: 6 });
  const before = (await page.send("status")).snapshot;
  const forward = await page.jump(6, before);
  assert.equal(forward.ok, true);
  assert.equal(forward.snapshot.position, 6);
  assert.equal(forward.snapshot.slideID, "id.slide6");
  assert.equal(forward.ended, undefined);
  const backward = await page.jump(2, forward.snapshot);
  assert.equal(backward.ok, true);
  assert.equal(backward.snapshot.position, 2);
  assert.deepEqual(page.state.actions, [6, 2]);
});

test("same-slide jump verifies order and returns unchanged snapshot without selecting slide", async () => {
  const page = slideshow({ position: 2, selected: 2 });
  const before = (await page.send("status")).snapshot;
  const result = await page.jump(2, before);
  assert.equal(result.ok, true);
  assert.deepEqual(result.snapshot, before);
  assert.equal(result.ended, undefined);
  assert.deepEqual(page.state.actions, []);
  page.state.selected = 1;
  assert.equal((await page.jump(2, before)).ok, false);
  assert.deepEqual(page.state.actions, []);
});

test("invalid jump targets and missing expected snapshot never select a slide", async () => {
  const page = slideshow();
  const before = (await page.send("status")).snapshot;
  for (const target of [undefined, null, 0, -1, 4, 1.5, "2", NaN, Infinity]) {
    const result = await page.jump(target, before);
    assert.equal(result.ok, false);
    assert.match(result.error, /target slide/);
  }
  assert.equal((await page.jump(2)).ok, false);
  for (const operation of ["advance", "status"]) {
    assert.equal((await page.send(operation, before, "extension-test", { targetPosition: 2 })).ok, false);
  }
  assert.deepEqual(page.state.actions, []);
});

test("manual slide movement and stale jump identity fail before dispatch", async () => {
  for (const patch of [{ deckID: "different" }, { pageID: "old-page" }, { slideID: "id.old" }, { position: 2 }, { total: 4 }]) {
    const page = slideshow();
    const before = (await page.send("status")).snapshot;
    assert.equal((await page.jump(3, { ...before, ...patch })).ok, false);
    assert.deepEqual(page.state.actions, []);
  }
  const page = slideshow();
  const before = (await page.send("status")).snapshot;
  page.state.position = 2; page.state.selected = 2; page.setSlideID(2);
  assert.equal((await page.jump(3, before)).ok, false);
  assert.deepEqual(page.state.actions, []);
});

test("jump waits for target slide identity and never retries unconfirmed movement", async () => {
  const delayed = slideshow({ total: 6, delayURL: true });
  const result = await delayed.jump(5, (await delayed.send("status")).snapshot);
  assert.equal(result.ok, true);
  assert.equal(result.snapshot.slideID, "id.slide5");
  assert.deepEqual(delayed.state.actions, [5]);
  for (const options of [{ ignoreActions: true }, { unexpectedJump: true }]) {
    const page = slideshow({ total: 6, ...options });
    const failure = await page.jump(4, (await page.send("status")).snapshot);
    assert.equal(failure.ok, false);
    assert.match(failure.error, /no retry/);
    assert.deepEqual(page.state.actions, [4]);
  }
});

test("status initializes lazy picker without moving slides", async () => {
  const page = slideshow({ initialized: false });
  const result = await page.send("status");
  assert.equal(result.ok, true);
  assert.equal(result.contentBuild, "0.5.5");
  assert.equal(result.snapshot.position, 1);
  assert.equal(page.state.pickerActions, 2);
  assert.deepEqual(page.state.actions, []);
});

test("readiness waits for loaded controls and slide identity without opening picker", async () => {
  const page = slideshow({ initialized: false, readyState: "loading" });
  assert.equal((await page.send("ready")).ready, false);
  page.state.readyState = "complete";
  assert.equal((await page.send("ready")).ready, true);
  page.state.captionCount = 0;
  assert.equal((await page.send("ready")).ready, false);
  assert.equal(page.state.pickerActions, 0);
  assert.deepEqual(page.state.actions, []);
  page.location.href = "https://docs.google.com/presentation/d/test-deck/edit";
  assert.equal((await page.send("ready")).ok, false);
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

test("URL-only History API update confirms forward and backward jumps without another DOM event", async () => {
  const page = slideshow({ total: 6, delayURL: true, quietURL: true });
  const initial = (await page.send("status")).snapshot;
  const forward = await page.jump(5, initial);
  assert.equal(forward.ok, true);
  assert.equal(forward.snapshot.slideID, "id.slide5");
  assert.equal(page.pendingChecks(), 0);
  const backward = await page.jump(2, forward.snapshot);
  assert.equal(backward.ok, true);
  assert.equal(backward.snapshot.slideID, "id.slide2");
  assert.deepEqual(page.state.actions, [5, 2]);
  assert.equal(page.pendingChecks(), 0);
});

test("caption replacement during a slide transition waits for exact target without redispatch", async () => {
  const page = slideshow({
    onSelect(position) {
      page.state.captionCount = 0;
      page.mutate();
      setTimeout(() => {
        page.state.position = position;
        page.state.selected = position;
        page.state.captionCount = 1;
        page.setSlideID(position);
      }, 10);
    },
  });
  const next = await page.send("advance", (await page.send("status")).snapshot);
  assert.equal(next.ok, true);
  assert.equal(next.snapshot.position, 2);
  assert.equal(next.snapshot.slideID, "id.slide2");
  assert.deepEqual(page.state.actions, [2]);
  assert.equal(page.pendingChecks(), 0);
});

test("missing caption is fatal before dispatch and bounded during confirmation", async () => {
  const page = slideshow();
  const initial = (await page.send("status")).snapshot;
  page.state.captionCount = 0;
  assert.equal((await page.send("status")).ok, false);
  assert.equal((await page.send("advance", initial)).ok, false);
  assert.deepEqual(page.state.actions, []);
  assert.equal(page.pendingChecks(), 0);
  page.state.captionCount = 1;
  page.state.onSelect = () => { page.state.captionCount = 0; page.mutate(); };
  const result = await page.send("advance", initial);
  assert.equal(result.ok, false);
  assert.match(result.error, /did not confirm/);
  assert.deepEqual(page.state.actions, [2]);
  assert.equal(page.pendingChecks(), 0);
});

test("transition polling preserves fatal document, blank-screen, ambiguous-control and target checks", async () => {
  for (const [change, error] of [
    [page => { page.state.captionCount = 0; page.location.href = "https://docs.google.com/presentation/d/other-deck/present?slide=id.slide2"; }, /slideshow changed/],
    [page => { page.state.captionCount = 0; page.location.href = "https://docs.google.com/presentation/d/test-deck/edit"; }, /Slideshow mode/],
    [page => { page.state.captionCount = 0; page.state.blank = true; }, /blank screen/],
    [page => { page.state.captionCount = 2; }, /ambiguous/],
    [page => { page.state.position = 3; page.state.selected = 3; page.setSlideID(3, false); }, /unexpected slide/],
    [page => { page.state.total = 4; }, /slideshow changed/],
    [page => { page.event("pagehide"); }, /document left/],
    [page => { page.state.captionCount = 0; page.event("pagehide"); page.event("pageshow", { persisted: true, isTrusted: true }); }, /slideshow changed/],
  ]) {
    const page = slideshow({ onSelect() { change(page); page.mutate(); } });
    const result = await page.send("advance", (await page.send("status")).snapshot);
    assert.equal(result.ok, false);
    assert.match(result.error, error);
    assert.deepEqual(page.state.actions, [2]);
    assert.equal(page.pendingChecks(), 0);
  }
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
