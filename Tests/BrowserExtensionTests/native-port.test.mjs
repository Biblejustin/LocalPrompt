import test from "node:test";
import assert from "node:assert/strict";
import { isSafari, openNativePort } from "../../BrowserExtension/native-port.js";

class Event {
  listeners = [];
  addListener(fn) { this.listeners.push(fn); }
  fire(...args) { for (const fn of this.listeners) fn(...args); }
}

function safariRuntime(replies = []) {
  const state = { sent: [], inboundClosed: false };
  const inbound = { onMessage: new Event(), onDisconnect: new Event(), disconnect() { state.inboundClosed = true; } };
  const runtime = {
    getURL: () => "safari-web-extension://ABC/",
    connectNative(name) { assert.equal(name, "com.biblejustin.localprompt.slides"); return inbound; },
    async sendNativeMessage(name, message) {
      assert.equal(name, "com.biblejustin.localprompt.slides");
      state.sent.push(message.frame);
      const reply = replies.shift() ?? { ok: true };
      if (reply instanceof Error) throw reply;
      return reply;
    },
  };
  return { runtime, inbound, state };
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test("Chrome and Brave keep the native host port", () => {
  const port = {};
  const runtime = { getURL: () => "chrome-extension://abc/", connectNative(name) { assert.equal(name, "com.biblejustin.localprompt.slides"); return port; } };
  assert.equal(isSafari(runtime), false);
  assert.equal(openNativePort(runtime), port);
});

test("A runtime without getURL is treated as Chrome", () => {
  assert.equal(isSafari({}), false);
});

test("Safari sends frames in order and unwraps LocalPrompt's replies", async () => {
  const { runtime, inbound, state } = safariRuntime();
  assert.equal(isSafari(runtime), true);
  const port = openNativePort(runtime);
  const received = [];
  port.onMessage.addListener(frame => received.push(frame));
  port.postMessage({ type: "hello", n: 1 });
  port.postMessage({ type: "result", n: 2 });
  await settle(); await settle();
  assert.deepEqual(state.sent.map(frame => frame.n), [1, 2]);
  inbound.onMessage.fire({ name: "frame", userInfo: { frame: { type: "command", requestID: 1 } } });
  inbound.onMessage.fire({ name: "other" });
  assert.deepEqual(received, [{ type: "command", requestID: 1 }]);
});

test("A refused frame closes the Safari port once", async () => {
  const { runtime, state } = safariRuntime([{ ok: false }]);
  const port = openNativePort(runtime);
  let closes = 0;
  port.onDisconnect.addListener(() => closes++);
  port.postMessage({ type: "hello" });
  await settle(); await settle();
  assert.equal(closes, 1);
  assert.equal(state.inboundClosed, true);
  assert.throws(() => port.postMessage({ type: "result" }), /not connected/);
});

test("A failed native call closes the Safari port", async () => {
  const { runtime } = safariRuntime([new Error("no handler")]);
  const port = openNativePort(runtime);
  let closes = 0;
  port.onDisconnect.addListener(() => closes++);
  port.postMessage({ type: "hello" });
  await settle(); await settle();
  assert.equal(closes, 1);
});

test("LocalPrompt closing its side reaches the extension", () => {
  const { runtime, inbound } = safariRuntime();
  const port = openNativePort(runtime);
  let closes = 0;
  port.onDisconnect.addListener(() => closes++);
  inbound.onDisconnect.fire();
  inbound.onDisconnect.fire();
  assert.equal(closes, 1);
});

test("Our own disconnect still delivers the queued goodbye without a close event", async () => {
  const { runtime, state } = safariRuntime();
  const port = openNativePort(runtime);
  let closes = 0;
  port.onDisconnect.addListener(() => closes++);
  port.postMessage({ type: "disconnect" });
  port.disconnect();
  await settle(); await settle();
  assert.deepEqual(state.sent, [{ type: "disconnect" }]);
  assert.equal(closes, 0);
  assert.equal(state.inboundClosed, true);
});
