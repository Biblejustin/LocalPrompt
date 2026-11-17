import { NATIVE_HOST } from "./protocol.js";

// Chrome and Brave start LocalPrompt's helper and keep one stdio port open.
// Safari instead hands each message to LocalPrompt's own extension handler and
// returns its reply, and LocalPrompt answers on a port opened with
// connectNative. This wrapper gives both the same port shape.
export function isSafari(runtime) {
  try { return String(runtime.getURL("")).startsWith("safari-web-extension:"); } catch { return false; }
}

export function openNativePort(runtime) {
  return isSafari(runtime) ? safariPort(runtime) : runtime.connectNative(NATIVE_HOST);
}

function safariPort(runtime) {
  const messageListeners = [];
  const disconnectListeners = [];
  let closed = false;
  let queue = Promise.resolve();
  const inbound = runtime.connectNative(NATIVE_HOST);
  // LocalPrompt's side closed or refused a frame: behave like a closed port.
  const lost = () => {
    if (closed) return;
    closed = true;
    try { inbound.disconnect(); } catch { /* already closed */ }
    for (const listener of disconnectListeners) listener();
  };
  inbound.onMessage.addListener(message => {
    if (closed) return;
    const frame = message?.userInfo?.frame ?? message?.frame;
    if (frame && typeof frame === "object") for (const listener of messageListeners) listener(frame);
  });
  inbound.onDisconnect.addListener(lost);
  return {
    onMessage: { addListener(listener) { messageListeners.push(listener); } },
    onDisconnect: { addListener(listener) { disconnectListeners.push(listener); } },
    postMessage(frame) {
      if (closed) throw new Error("LocalPrompt is not connected.");
      // Each frame is delivered before the next is sent, keeping their order.
      queue = queue
        .then(() => runtime.sendNativeMessage(NATIVE_HOST, { frame }))
        .then(reply => { if (reply?.ok !== true) lost(); }, lost);
    },
    // Like Chrome's port.disconnect(): no onDisconnect for our own close.
    disconnect() {
      closed = true;
      try { inbound.disconnect(); } catch { /* already closed */ }
    },
  };
}
