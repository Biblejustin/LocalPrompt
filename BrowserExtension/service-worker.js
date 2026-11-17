import { VERSION, CHANNEL, presentationID, slideshowSelection, validSnapshot, validateCommand, errorText } from "./protocol.js";
import { openNativePort } from "./native-port.js";

const CONNECTOR_BUILD = "0.5.5";
let connection = null;
let attempt = null;
let lastError = "";

function publicStatus() {
  return {
    connected: Boolean(connection), paired: Boolean(connection?.paired),
    connecting: Boolean(attempt || (connection && !connection.paired)),
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
  attempt = null;
  const previous = connection;
  connection = null;
  lastError = reason;
  if (!previous) return;
  clearTimeout(previous.handshakeTimer);
  if (notifyNative) {
    try { previous.port.postMessage({ v: VERSION, type: "disconnect", session: previous.session, ...(reason ? { error: reason } : {}) }); }
    catch { /* The native app may already have closed its port. */ }
  }
  previous.port.disconnect();
}

function checkAttempt(current) {
  if (attempt !== current) throw new Error("Slide connection canceled.");
}

async function selectedTab(current) {
  checkAttempt(current);
  const tab = await bounded(chrome.tabs.get(current.tabId));
  checkAttempt(current);
  const selection = slideshowSelection(tab.url);
  if (selection?.deckID !== current.deckID || (current.arrived && selection.route !== "present")) {
    throw new Error("The selected tab changed while connecting. Select the deck again.");
  }
  if (selection.route === "present") current.arrived = true;
  return tab;
}

async function prepareSlideshow(current) {
  const deadline = Date.now() + 15000;
  let injected = false;
  while (Date.now() < deadline) {
    const tab = await selectedTab(current);
    if (current.arrived && tab.status !== "loading") {
      if (!injected) {
        await bounded(chrome.scripting.executeScript({ target: { tabId: current.tabId, frameIds: [0] }, files: ["content.js"] }));
        checkAttempt(current);
        injected = true;
      }
      const ready = await bounded(chrome.tabs.sendMessage(current.tabId, { channel: CHANNEL, operation: "ready" }, { frameId: 0 }));
      checkAttempt(current);
      if (ready?.contentBuild !== CONNECTOR_BUILD) throw new Error("The slideshow is using an older connector. Refresh the slideshow tab, then reconnect.");
      if (!ready?.ok) throw new Error(ready?.error || "Could not prepare this slideshow.");
      if (ready.ready) return;
    }
    await new Promise(resolve => setTimeout(resolve, 150));
  }
  throw new Error("Google Slides is still loading. Wait for the slide, then connect again.");
}

async function contentRequest(target, operation, expected, targetPosition) {
  const tab = await chrome.tabs.get(target.tabId);
  if (connection !== target) throw new Error("Slide connection was canceled before dispatch.");
  if (presentationID(tab.url) !== target.snapshot.deckID) throw new Error("The selected tab left its Google Slides slideshow. Connect again.");
  const result = await chrome.tabs.sendMessage(target.tabId, {
    channel: CHANNEL, operation, ...(expected ? { expected } : {}),
    ...(operation === "goToSlide" ? { targetPosition } : {}),
  }, { frameId: 0 });
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
    const result = await contentRequest(target, command.operation, command.snapshot, command.targetPosition);
    if (connection !== target) return;
    target.snapshot = result.snapshot;
    if (command.operation === "status") {
      target.paired = true;
      clearTimeout(target.handshakeTimer);
    }
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
  if (attempt || (connection && !connection.paired)) throw new Error("A slideshow connection is already in progress.");
  disconnect();
  const current = {};
  attempt = current;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    checkAttempt(current);
    const selection = slideshowSelection(tab?.url);
    if (!tab?.id || !selection) throw new Error("Open a Google Slides deck, then click Connect this deck. Presenter-notes and published tabs are not supported.");
    Object.assign(current, { tabId: tab.id, deckID: selection.deckID, arrived: selection.route === "present" });
    if (selection.route === "edit") {
      // Keep the same tab: its explicit activeTab grant survives this same-origin
      // navigation. Back returns to the editor; no broader host permission.
      await bounded(chrome.tabs.update(tab.id, { url: selection.url }));
      checkAttempt(current);
    }
    await prepareSlideshow(current);
    const initial = await bounded(chrome.tabs.sendMessage(tab.id, { channel: CHANNEL, operation: "status" }, { frameId: 0 }));
    checkAttempt(current);
    if (initial?.contentBuild !== CONNECTOR_BUILD) throw new Error("The slideshow is using an older connector. Refresh the slideshow tab, then reconnect.");
    if (!initial?.ok) throw new Error(initial?.error || "Could not read this slideshow.");
    if (!validSnapshot(initial.snapshot) || initial.snapshot.deckID !== selection.deckID) throw new Error("Google Slides returned an invalid position.");
    const verifiedTab = await selectedTab(current);
    if (presentationID(verifiedTab.url) !== selection.deckID) throw new Error("The selected tab left its slideshow while connecting.");
    const port = openNativePort(chrome.runtime);
    const target = { tabId: tab.id, session: crypto.randomUUID(), snapshot: initial.snapshot, contentBuild: initial.contentBuild, lastRequestID: 0, commands: Promise.resolve(), port, paired: false };
    connection = target;
    target.handshakeTimer = setTimeout(() => {
      if (connection === target && !target.paired) disconnect("LocalPrompt did not finish pairing. Open LocalPrompt, pause reading, then connect this deck again.");
    }, 10000);
    port.onMessage.addListener(message => nativeMessage(target, message));
    port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message;
      if (connection === target) {
        clearTimeout(target.handshakeTimer);
        connection = null;
        lastError = error
          ? "Open LocalPrompt, then connect this deck again. For first-time setup, use Prepare Brave extension in LocalPrompt."
          : "LocalPrompt disconnected. Reconnect this slideshow when ready.";
      }
    });
    port.postMessage({ v: VERSION, type: "hello", session: target.session, snapshot: target.snapshot });
    lastError = "";
    return publicStatus();
  } catch (error) {
    if (attempt === current) disconnect(errorText(error));
    throw error;
  } finally { if (attempt === current) attempt = null; }
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
  connect().then(() => replyToPopup({ ok: true, ...publicStatus() }), error => replyToPopup({ ok: false, ...publicStatus(), error: errorText(error) }));
  return true;
});

chrome.tabs.onRemoved.addListener(tabID => { if (connection?.tabId === tabID || attempt?.tabId === tabID) disconnect("The selected slideshow tab closed."); });
chrome.tabs.onReplaced.addListener((_added, removed) => { if (connection?.tabId === removed || attempt?.tabId === removed) disconnect("The slideshow tab was replaced. Reconnect before continuing."); });
chrome.tabs.onUpdated.addListener((tabID, change) => {
  if (attempt?.tabId === tabID && (change.url || change.status === "complete")) {
    const current = attempt;
    void selectedTab(current).catch(error => { if (attempt === current) disconnect(errorText(error)); });
  }
  if (connection?.tabId !== tabID) return;
  // Brave emits loading/complete for Slides' same-document URL changes too.
  // pagehide invalidates real navigation immediately; this nonce probe catches
  // reloads whose unloading script could not deliver its notification.
  if (change.url || change.status === "complete") void verifyTabChange(connection);
});
