// "Open in Facebook" — content script.
//
// Sends the original Facebook HTTPS URL through Facebook's already-registered
// fb:// scheme. FacebookPlus intercepts the private fbbridge route and feeds the
// HTTPS URL into Facebook's own Universal Link handler.
//
// Using the existing fb:// registration means TrollFools injection needs only
// FacebookPlus.dylib; no CFBundleURLTypes edit is required.

(() => {
  "use strict";

  const attemptKey = () => `open-in-facebook:${window.location.href}`;

  function markerURL() {
    try {
      const url = new URL(window.location.href);
      const marker = url.hash.match(/(?:^#|&)open-in-facebook=([^&]+)/)?.[1];
      return marker ? decodeURIComponent(marker) : null;
    } catch {
      return null;
    }
  }

  function originalFacebookURL() {
    const marked = markerURL();
    if (marked) {
      try {
        const parsed = new URL(marked);
        if (parsed.protocol === "http:" || parsed.protocol === "https:") return parsed.href;
      } catch {}
    }
    return window.location.href;
  }

  function openInApp() {
    const target = originalFacebookURL();
    const now = Date.now();
    const previous = Number(sessionStorage.getItem(attemptKey()) || 0);
    if (now - previous < 5000) return;

    try {
      sessionStorage.setItem(attemptKey(), String(now));
    } catch {}

    const bridgeURL = `fb://fbbridge/open?url=${encodeURIComponent(target)}`;
    window.location.replace(bridgeURL);
  }

  openInApp();
})();
