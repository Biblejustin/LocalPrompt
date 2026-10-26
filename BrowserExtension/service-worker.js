import { VERSION, CHANNEL, NATIVE_HOST, presentationID, validSnapshot, validateCommand, errorText } from "./protocol.js";

const CONNECTOR_BUILD = "0.4.0.2";
let connection = null;
let connecting = false;
let lastError = "";

function publicStatus() {
  return {
    connected: Boolean(connection), connecting,
    connectorBuild: CONNECTOR_BUILD,
    contentBuild: connection?.contentBuild ?? null,
    snapshot: connection?.snapshot ?? null,
    error: lastError,
  };
}

function bounded(promise) {
  let timer;
  const deadline = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("Slideshow verification timed out.")), 2000);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

function navigationSummary(value, expectedDeckID) {
  try {
    const url = new URL(value);
    const last = url.pathname.split("/").filter(Boolean).at(-1) || "root";
    const page = ["present", "edit", "preview", "pub", "embed"].includes(last) ? last : "other";
    const deck = /\/presentation\/(?:u\/\d+\/)?d\/([A-Za-z0-9_-]+)/.exec(url.pathname)?.[1];
    return `origin ${url.origin.slice(0, 150)}, page ${page}, deck ${deck === expectedDeckID ? "same" : "different or absent"}`;
  } catch { return "unreadable tab address"; }
}

function disconnect(reason = "", notifyNative = true) {
  const previous = connection;
  connection = null;
  lastError = reason;
  if (!previous) return;
  if (notifyNative) {
    try { previous.port.postMessage({ v: VERSION, type: "disconnect", session: previous.session, ...(reason ? { error: reason } : {}) }); }
    catch { /* The native app may already have closed its port. */ }
  }
  previous.port.disconnect();
}

async function contentRequest(target, operation, expected) {
  const tab = await chrome.tabs.get(target.tabId);
  if (connection !== target) throw new Error("Slide connection was canceled before dispatch.");
  if (presentationID(tab.url) !== target.snapshot.deckID) throw new Error("The selected tab left its Google Slides slideshow. Connect again.");
  const result = await chrome.tabs.sendMessage(target.tabId, { channel: CHANNEL, operation, ...(expected ? { expected } : {}) }, { frameId: 0 });
  if (result?.contentBuild !== CONNECTOR_BUILD) throw new Error("The slideshow is using an older connector. Refresh the slideshow tab, then reconnect.");
  if (!result?.ok) throw new Error(result?.error || "The slideshow did not respond. Reconnect before continuing.");
  if (!validSnapshot(result.snapshot) || result.snapshot.deckID !== target.snapshot.deckID || result.snapshot.pageID !== target.snapshot.pageID) {
    throw new Error("The slideshow page changed. Reconnect before continuing.");
  }
  return result;
}

async function verifyDocument(target) {
  if (connection !== target) return;
  try {
    const result = await bounded(chrome.tabs.sendMessage(target.tabId, { channel: CHANNEL, operation: "identity" }, { frameId: 0 }));
    if (connection !== target) return;
    if (!result?.ok || result.contentBuild !== CONNECTOR_BUILD || result.identity?.pageID !== target.snapshot.pageID || result.identity?.deckID !== target.snapshot.deckID) {
      throw new Error("The slideshow document changed.");
    }
  } catch {
    if (connection === target) disconnect("The slideshow reloaded or left its document. Reconnect before continuing.");
  }
}

async function verifyTabChange(target) {
  if (connection !== target) return;
  try {
    // onUpdated.change.url can be transient during a Slides transition. Check
    // the browser's current tab state, then the content document's nonce.
    const tab = await bounded(chrome.tabs.get(target.tabId));
    if (connection !== target) return;
    if (presentationID(tab.url) !== target.snapshot.deckID) {
      disconnect(`The selected slideshow tab changed (${navigationSummary(tab.url, target.snapshot.deckID)}). Reconnect before continuing.`);
      return;
    }
    await verifyDocument(target);
  } catch {
    if (connection === target) disconnect("Could not verify the selected slideshow tab. Reconnect before continuing.");
  }
}

function reply(target, command, result) {
  if (connection !== target) return;
  target.port.postMessage({ v: VERSION, type: "result", session: target.session, requestID: command.requestID, ...result });
}

async function executeCommand(target, command) {
  if (connection !== target) return;
  try {
    const result = await contentRequest(target, command.operation, command.snapshot);
    if (connection !== target) return;
    target.snapshot = result.snapshot;
    reply(target, command, { snapshot: result.snapshot, ...(result.ended ? { ended: true } : {}) });
  } catch (error) {
    if (connection !== target) return;
    const message = errorText(error);
    try { reply(target, command, { error: message }); } finally { disconnect(message); }
  }
}

function nativeMessage(target, message) {
  if (connection !== target) return;
  if (message?.v === VERSION && message.type === "disconnect" && message.session === target.session) {
    disconnect(typeof message.error === "string" ? message.error.slice(0, 600) : "", false);
    return;
  }
  try {
    validateCommand(message, target);
    target.lastRequestID = message.requestID;
    target.commands = target.commands.then(() => executeCommand(target, message));
  } catch (error) {
    const reason = errorText(error);
    try {
      if (Number.isSafeInteger(message?.requestID)) reply(target, message, { error: reason });
    } finally { disconnect(reason); }
  }
}

async function connect() {
  if (connecting) throw new Error("A slideshow connection is already in progress.");
  connecting = true;
  disconnect();
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const deckID = presentationID(tab?.url);
    if (!tab?.id || !deckID) throw new Error("Open Google Slides in Slideshow mode, then click Connect this slideshow. Editing and presenter-notes tabs are not supported.");
    await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, files: ["content.js"] });
    const initial = await chrome.tabs.sendMessage(tab.id, { channel: CHANNEL, operation: "status" }, { frameId: 0 });
    if (initial?.contentBuild !== CONNECTOR_BUILD) throw new Error("The slideshow is using an older connector. Refresh the slideshow tab, then reconnect.");
    if (!initial?.ok) throw new Error(initial?.error || "Could not read this slideshow.");
    if (!validSnapshot(initial.snapshot) || initial.snapshot.deckID !== deckID) throw new Error("Google Slides returned an invalid position.");
    const port = chrome.runtime.connectNative(NATIVE_HOST);
    const target = { tabId: tab.id, session: crypto.randomUUID(), snapshot: initial.snapshot, contentBuild: initial.contentBuild, lastRequestID: 0, commands: Promise.resolve(), port };
    connection = target;
    port.onMessage.addListener(message => nativeMessage(target, message));
    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message;
      if (connection === target) {
        connection = null;
        lastError = error
          ? "LocalPrompt's slide bridge is unavailable. Open LocalPrompt, click Prepare Brave extension, then reconnect this slideshow."
          : "LocalPrompt disconnected. Reconnect this slideshow when ready.";
      }
    });
    port.postMessage({ v: VERSION, type: "hello", session: target.session, snapshot: target.snapshot });
    lastError = "";
    return publicStatus();
  } catch (error) {
    disconnect(errorText(error));
    throw error;
  } finally { connecting = false; }
}

chrome.runtime.onMessage.addListener((message, sender, replyToPopup) => {
  if (sender.id !== chrome.runtime.id || message?.channel !== CHANNEL) return false;
  if (message.action === "page-leaving") {
    // Only the bound top-frame content script can retire this document. Late
    // notifications from an older page must not disconnect a newer session.
    if (connection && sender.tab?.id === connection.tabId && sender.frameId === 0 &&
        message.pageID === connection.snapshot.pageID && message.deckID === connection.snapshot.deckID) {
      disconnect("The slideshow document closed or reloaded. Reconnect before continuing.");
    }
    return false;
  }
  // Only this extension's own popup can select or disconnect a tab.
  if (sender.tab) return false;
  if (message.action === "status") { replyToPopup({ ok: true, ...publicStatus() }); return false; }
  if (message.action === "disconnect") { disconnect(); replyToPopup({ ok: true, ...publicStatus() }); return false; }
  if (message.action !== "connect") return false;
  connect().then(status => replyToPopup({ ok: true, ...status, connecting: false }), error => replyToPopup({ ok: false, ...publicStatus(), connecting: false, error: errorText(error) }));
  return true;
});

chrome.tabs.onRemoved.addListener(tabID => { if (connection?.tabId === tabID) disconnect("The selected slideshow tab closed."); });
chrome.tabs.onReplaced.addListener((_added, removed) => { if (connection?.tabId === removed) disconnect("The slideshow tab was replaced. Reconnect before continuing."); });
chrome.tabs.onUpdated.addListener((tabID, change) => {
  if (connection?.tabId !== tabID) return;
  // Brave emits loading/complete for Slides' same-document URL changes too.
  // pagehide invalidates real navigation immediately; this nonce probe catches
  // reloads whose unloading script could not deliver its notification.
  if (change.url || change.status === "complete") void verifyTabChange(connection);
});
