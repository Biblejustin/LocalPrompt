export const VERSION = 1;
export const CHANNEL = "localprompt-slides-v1";
export const NATIVE_HOST = "com.biblejustin.localprompt.slides";

export function presentationID(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "docs.google.com" || url.port || url.username || url.password) return null;
    return /^\/presentation\/d\/([A-Za-z0-9_-]+)\/present\/?$/.exec(url.pathname)?.[1] ?? null;
  } catch { return null; }
}

// Selection can start in the editor, but control is still restricted to the
// standalone slideshow. Never copy arbitrary query values (including tokens).
export function slideshowSelection(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "docs.google.com" || url.port || url.username || url.password) return null;
    const match = /^\/presentation\/d\/([A-Za-z0-9_-]{1,256})\/(edit|present)\/?$/.exec(url.pathname);
    if (!match) return null;
    const [, deckID, route] = match;
    const canonical = new URL(`https://docs.google.com/presentation/d/${deckID}/present`);
    // The editor updates its hash as selection moves; its query can lag behind.
    const hashSlide = new URLSearchParams(url.hash.slice(1)).get("slide");
    const querySlide = url.searchParams.get("slide");
    const slide = route === "edit" ? hashSlide || querySlide : querySlide || hashSlide;
    if (slide && /^id\.[A-Za-z0-9_.-]{1,253}$/.test(slide)) canonical.searchParams.set("slide", slide);
    return { deckID, route, url: canonical.href };
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
  if (!["status", "advance", "goToSlide"].includes(message.operation)) throw new Error("Unsupported slide command.");
  if (message.operation !== "status" && !validSnapshot(message.snapshot)) throw new Error("Missing or invalid expected slide position.");
  if (message.operation === "goToSlide") {
    if (!Number.isSafeInteger(message.targetPosition) || message.targetPosition < 1 || message.targetPosition > message.snapshot.total) {
      throw new Error("Missing or invalid target slide position.");
    }
  } else if (Object.hasOwn(message, "targetPosition")) {
    throw new Error("Unexpected target slide position.");
  }
}

export function errorText(error) {
  return String(error?.message ?? error ?? "Slide control failed.").slice(0, 600);
}
