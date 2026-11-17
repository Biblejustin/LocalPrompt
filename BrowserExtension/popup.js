import { CHANNEL, errorText } from "./protocol.js";

const status = document.querySelector("#status");
const error = document.querySelector("#error");
const connect = document.querySelector("#connect");
const disconnect = document.querySelector("#disconnect");
const build = document.querySelector("#build");
const extensionVersion = chrome.runtime.getManifest().version;
let busy = false;
let requestID = 0;

function render(state) {
  build.textContent = `Extension ${extensionVersion} · connector ${state.connectorBuild || "unavailable"}${state.contentBuild ? ` · page ${state.contentBuild}` : ""}`;
  error.textContent = state.error || "";
  error.hidden = !state.error;
  connect.disabled = busy || state.connecting;
  disconnect.disabled = false;
  connect.hidden = state.connected || state.connecting;
  disconnect.hidden = !(state.connected || state.connecting || busy);
  status.textContent = state.paired
    ? `${state.snapshot.title || "Google Slides"} · slide ${state.snapshot.position} of ${state.snapshot.total}. Connected. Start reading in LocalPrompt when ready.`
    : state.connecting ? "Opening slideshow and pairing with LocalPrompt…" : "No slideshow selected.";
}

async function request(action) {
  if (busy && action !== "disconnect") return;
  const current = ++requestID;
  busy = true;
  connect.disabled = true;
  disconnect.disabled = true;
  if (action === "connect") {
    status.textContent = "Opening slideshow and pairing with LocalPrompt…";
    connect.hidden = true;
    disconnect.hidden = false;
    disconnect.disabled = false;
  }
  try {
    const state = await chrome.runtime.sendMessage({ channel: CHANNEL, action });
    if (current !== requestID) return;
    busy = false;
    render(state || { error: "LocalPrompt extension did not respond." });
  } catch (failure) {
    if (current !== requestID) return;
    busy = false;
    render({ error: errorText(failure) });
  }
}

connect.addEventListener("click", () => request("connect"));
disconnect.addEventListener("click", () => request("disconnect"));
request("status");
// The native bridge can reject a connection after the popup's initial reply.
setInterval(() => { if (!busy) request("status"); }, 1000);
