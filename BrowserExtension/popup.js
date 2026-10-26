import { CHANNEL, errorText } from "./protocol.js";

const status = document.querySelector("#status");
const error = document.querySelector("#error");
const connect = document.querySelector("#connect");
const disconnect = document.querySelector("#disconnect");
const build = document.querySelector("#build");
const extensionVersion = chrome.runtime.getManifest().version;
let busy = false;

function render(state) {
  build.textContent = `Extension ${extensionVersion} · connector ${state.connectorBuild || "unavailable"}${state.contentBuild ? ` · page ${state.contentBuild}` : ""}`;
  error.textContent = state.error || "";
  error.hidden = !state.error;
  connect.disabled = busy || state.connecting;
  disconnect.disabled = busy;
  connect.hidden = state.connected;
  disconnect.hidden = !state.connected;
  status.textContent = state.connected
    ? `${state.snapshot.title || "Google Slides"} · slide ${state.snapshot.position} of ${state.snapshot.total}. Selected. Return to LocalPrompt and click Connect Google Slides.`
    : "No slideshow selected.";
}

async function request(action) {
  if (busy) return;
  busy = true;
  connect.disabled = true;
  disconnect.disabled = true;
  try {
    const state = await chrome.runtime.sendMessage({ channel: CHANNEL, action });
    busy = false;
    render(state || { error: "LocalPrompt extension did not respond." });
  } catch (failure) {
    busy = false;
    render({ error: errorText(failure) });
  }
}

connect.addEventListener("click", () => request("connect"));
disconnect.addEventListener("click", () => request("disconnect"));
request("status");
// The native bridge can reject a connection after the popup's initial reply.
setInterval(() => { if (!busy) request("status"); }, 1000);
