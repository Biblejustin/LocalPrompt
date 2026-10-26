export const VERSION = 1;
export const CHANNEL = "localprompt-slides-v1";
export const NATIVE_HOST = "com.biblejustin.localprompt.slides";

export function presentationID(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "docs.google.com" || url.port) return null;
    return /^\/presentation\/d\/([A-Za-z0-9_-]+)\/present\/?$/.exec(url.pathname)?.[1] ?? null;
  } catch { return null; }
}

export function validSnapshot(value) {
  return value && typeof value === "object" &&
    typeof value.deckID === "string" && /^[A-Za-z0-9_-]{1,256}$/.test(value.deckID) &&
    typeof value.pageID === "string" && value.pageID.length > 0 && value.pageID.length <= 128 &&
    typeof value.title === "string" && value.title.length <= 256 &&
    typeof value.slideID === "string" && value.slideID.length > 0 && value.slideID.length <= 256 &&
    Number.isSafeInteger(value.position) && Number.isSafeInteger(value.total) &&
    value.position >= 1 && value.position <= value.total && value.total <= 10000;
}

export function validateCommand(message, connection) {
  if (!message || message.v !== VERSION || message.type !== "command" ||
      message.session !== connection.session) throw new Error("Invalid slide-control session.");
  if (!Number.isSafeInteger(message.requestID) || message.requestID < 1 ||
      message.requestID <= connection.lastRequestID) throw new Error("Duplicate or out-of-order slide command. Reconnect before continuing.");
  if (!["status", "advance"].includes(message.operation)) throw new Error("Unsupported slide command.");
  if (message.operation === "advance" && !validSnapshot(message.snapshot)) throw new Error("Missing or invalid expected slide position.");
}

export function errorText(error) {
  return String(error?.message ?? error ?? "Slide control failed.").slice(0, 600);
}
