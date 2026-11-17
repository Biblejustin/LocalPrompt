// This script runs only in the isolated extension world of the tab selected by
// the user. It changes presentation playback, never the editable slide deck.
(() => {
  if (globalThis.__localPromptSlideCuesInstalled) return;
  globalThis.__localPromptSlideCuesInstalled = true;
  const CHANNEL = "localprompt-slides-v1";
  const CONTENT_BUILD = "0.5.5";
  let pageID = crypto.randomUUID();
  const captionSelector = '.punch-viewer-navbar-page[role="listbox"] [role="option"][aria-selected="true"]';
  const pickerSelector = '.punch-viewer-navbar-page[role="listbox"]';
  const itemSelector = '.punch-viewer-navbar-menu-content [role="menuitemradio"]';
  let busy = false;
  let leaving = false;

  // Slides can replace its caption node while moving between slides. Only
  // confirmation of an already-dispatched command may wait for it to return.
  class MissingSlideCaption extends Error {}

  function one(selector) {
    const nodes = document.querySelectorAll(selector);
    if (nodes.length !== 1) throw new Error("Google Slides controls are unavailable or ambiguous. Open one slideshow in this tab.");
    return nodes[0];
  }

  function presentationURL() {
    const url = new URL(location.href);
    const match = /^\/presentation\/d\/([A-Za-z0-9_-]+)\/present\/?$/.exec(url.pathname);
    if (url.protocol !== "https:" || url.hostname !== "docs.google.com" || url.port || !match) {
      throw new Error("Open Google Slides in Slideshow mode before connecting. Editing and presenter-notes tabs cannot be controlled.");
    }
    return { url, deckID: match[1] };
  }

  function snapshot() {
    const { url, deckID } = presentationURL();
    for (const overlay of document.querySelectorAll('.punch-viewer-interruption-black, .punch-viewer-interruption-white')) {
      const visible = overlay.checkVisibility
        ? overlay.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
        : overlay.getClientRects().length > 0 && getComputedStyle(overlay).visibility !== "hidden";
      if (visible) throw new Error("Google Slides is showing a blank screen. Restore the slide, then reconnect.");
    }
    if (document.querySelectorAll(captionSelector).length === 0) {
      throw new MissingSlideCaption("Google Slides controls are unavailable. Reopen the slideshow and reconnect.");
    }
    const caption = one(captionSelector);
    const position = Number(caption.getAttribute("aria-posinset"));
    const total = Number(caption.getAttribute("aria-setsize"));
    if (!Number.isSafeInteger(position) || !Number.isSafeInteger(total) || position < 1 || position > total || total > 10000) {
      throw new Error("Cannot verify the current Google Slides position. Reopen the slideshow and reconnect.");
    }
    const slideID = url.searchParams.get("slide") || new URLSearchParams(url.hash.slice(1)).get("slide") || "";
    if (!slideID || slideID.length > 256) throw new Error("Google Slides did not expose its current slide identifier. Reopen the slideshow and reconnect.");
    // 256 UTF-16 code units also fits the native bridge's 1024-byte UTF-8 limit.
    return { deckID, title: document.title.slice(0, 256), pageID, slideID, position, total };
  }

  // Google Slides uses a Closure menu. A plain HTMLElement.click() does not
  // select its entries; this exact mouse pair matches the menu's action path.
  // No browser activation, global keyboard event, or document write occurs.
  function selectMenuItem(node) {
    for (const type of ["mousedown", "mouseup"]) {
      if (leaving) throw new Error("The slideshow document is leaving. Reconnect before continuing.");
      node.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window, button: 0 }));
    }
  }

  function waitFor(read, action, timeoutMessage) {
    return new Promise((resolve, reject) => {
      let finished = false;
      let timer;
      let poll;
      const observer = new MutationObserver(check);
      function finish(error, value) {
        if (finished) return;
        finished = true;
        observer.disconnect();
        window.removeEventListener("hashchange", check);
        clearTimeout(timer);
        clearInterval(poll);
        error ? reject(error) : resolve(value);
      }
      function check() {
        if (finished) return;
        try { const value = read(); if (value) finish(null, value); }
        catch (error) { finish(error); }
      }
      observer.observe(document.documentElement, { subtree: true, attributes: true, childList: true, characterData: true });
      window.addEventListener("hashchange", check);
      // History API URL updates emit neither a DOM mutation nor hashchange.
      // Poll only while verifying this one action; never dispatch it again.
      poll = setInterval(check, 50);
      timer = setTimeout(() => {
        check();
        if (!finished) finish(new Error(timeoutMessage));
      }, 2500);
      try { action(); check(); } catch (error) { finish(error); }
    });
  }

  async function navigationItems() {
    let items = [...document.querySelectorAll(itemSelector)];
    if (items.length) return items;
    // The menu is lazy-created. Open and close once, without changing slides.
    const picker = one(pickerSelector);
    try {
      items = await waitFor(() => {
        const found = [...document.querySelectorAll(itemSelector)];
        return found.length ? found : null;
      }, () => selectMenuItem(picker), "Google Slides did not expose its slide picker. Reopen the slideshow and reconnect.");
    } finally { selectMenuItem(picker); }
    return items;
  }

  function checkedItems(items, current) {
    const checked = items.map((item, index) => item.getAttribute("aria-checked") === "true" ? index : -1).filter(index => index >= 0);
    if (items.length !== current.total || checked.length !== 1 || checked[0] !== current.position - 1) {
      throw new Error("Google Slides slide order could not be verified. Reconnect before continuing.");
    }
    return items;
  }

  function matches(actual, expected) {
    return expected && actual.deckID === expected.deckID && actual.pageID === expected.pageID &&
      actual.slideID === expected.slideID && actual.position === expected.position && actual.total === expected.total;
  }

  async function run(message) {
    if (leaving) throw new Error("The slideshow document is leaving. Reconnect before continuing.");
    if (message.operation !== "goToSlide" && Object.hasOwn(message, "targetPosition")) {
      throw new Error("Unexpected target slide position.");
    }
    // A browser loading/complete event can describe an ordinary slide URL
    // update. This read-only document probe must work during an active cue and
    // cannot depend on transient slide-picker rendering.
    if (message.operation === "identity") {
      return { identity: { pageID, deckID: presentationURL().deckID } };
    }
    if (message.operation === "ready") {
      presentationURL();
      const url = new URL(location.href);
      return { ready: document.readyState === "complete" &&
        document.querySelectorAll(captionSelector).length === 1 &&
        document.querySelectorAll(pickerSelector).length === 1 &&
        Boolean(url.searchParams.get("slide") || new URLSearchParams(url.hash.slice(1)).get("slide")) };
    }
    if (busy) throw new Error("A slide command is already in progress.");
    busy = true;
    try {
      if (message.operation === "status") {
        presentationURL();
        const items = await navigationItems();
        const current = snapshot();
        checkedItems(items, current);
        return { snapshot: current };
      }
      if (!["advance", "goToSlide"].includes(message.operation)) throw new Error("Unsupported slide command.");
      const before = snapshot();
      if (!matches(before, message.expected)) throw new Error("The Google Slides position changed. Align notes and slides, then reconnect.");
      const targetPosition = message.operation === "goToSlide" ? message.targetPosition : Math.min(before.position + 1, before.total);
      if (!Number.isSafeInteger(targetPosition) || targetPosition < 1 || targetPosition > before.total) {
        throw new Error("Missing or invalid target slide position.");
      }
      const items = checkedItems(await navigationItems(), before);
      if (!matches(snapshot(), before)) throw new Error("The slideshow changed while preparing the cue. Reconnect before continuing.");
      if (targetPosition === before.position) {
        return { snapshot: before, ...(message.operation === "advance" ? { ended: true } : {}) };
      }
      const after = await waitFor(() => {
        if (leaving) throw new Error("The slideshow document left during the cue. Reconnect before continuing; no retry was sent.");
        if (presentationURL().deckID !== before.deckID || pageID !== before.pageID) {
          throw new Error("The connected slideshow changed during the cue. Check it before reconnecting; no retry was sent.");
        }
        let current;
        try { current = snapshot(); }
        catch (error) {
          if (error instanceof MissingSlideCaption) return null;
          throw error;
        }
        if (current.deckID !== before.deckID || current.pageID !== before.pageID || current.total !== before.total) {
          throw new Error("The connected slideshow changed during the cue. Check it before reconnecting; no retry was sent.");
        }
        if (current.position === before.position) return null;
        if (current.position !== targetPosition) throw new Error("Google Slides moved to an unexpected slide. Check it before reconnecting; no retry was sent.");
        if (current.slideID === before.slideID) return null;
        // Caption, picker selection, and URL may update in separate mutations.
        try { checkedItems([...document.querySelectorAll(itemSelector)], current); }
        catch { return null; }
        return current;
      }, () => selectMenuItem(items[targetPosition - 1]), "Google Slides did not confirm the requested slide. Check the slideshow before reconnecting; no retry was sent.");
      return { snapshot: after };
    } finally { busy = false; }
  }

  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (sender.id !== chrome.runtime.id || message?.channel !== CHANNEL) return false;
    run(message).then(result => reply({ ok: true, contentBuild: CONTENT_BUILD, ...result }), error => reply({ ok: false, contentBuild: CONTENT_BUILD, error: String(error.message ?? error).slice(0, 600) }));
    return true;
  });

  window.addEventListener("pagehide", () => {
    leaving = true;
    try {
      chrome.runtime.sendMessage({ channel: CHANNEL, action: "page-leaving", pageID, deckID: presentationURL().deckID }).catch(() => {});
    } catch { /* A closing tab can invalidate the extension context first. */ }
  });
  window.addEventListener("pageshow", event => {
    // A restored BFCache page still requires a new explicit extension/native
    // connection; allow that handshake after the previous pagehide ended it.
    if (event.persisted && event.isTrusted) {
      pageID = crypto.randomUUID();
      leaving = false;
    }
  });
})();
