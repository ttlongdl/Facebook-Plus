// "Open in Facebook" — content script.
//
// Preserve the original Facebook HTTP(S) destination and pass it through
// Facebook's already-registered fb:// scheme. FacebookPlus intercepts the
// private fbbridge route and hands the normalized HTTPS URL to Facebook's own
// Universal Link handler.
//
// Handles desktop/mobile Facebook hosts (www, m, mbasic, mobile, touch, web,
// lm redirector) plus the Facebook short-link domains covered by manifest.json.

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

  function unwrapFacebookRedirect(raw) {
    try {
      const url = new URL(raw);
      const host = url.hostname.toLowerCase();
      if (host === "l.facebook.com" || host === "lm.facebook.com") {
        const nested = url.searchParams.get("u");
        if (nested) {
          const decoded = new URL(nested);
          if (decoded.protocol === "http:" || decoded.protocol === "https:") return decoded.href;
        }
      }
    } catch {}
    return raw;
  }

  function normalizeFacebookURL(raw) {
    raw = unwrapFacebookRedirect(raw);
    try {
      const url = new URL(raw);
      if (url.protocol !== "http:" && url.protocol !== "https:") return raw;

      const host = url.hostname.toLowerCase();
      const facebookHost =
        host === "facebook.com" ||
        host.endsWith(".facebook.com");

      if (facebookHost) {
        // Feed Facebook's Universal Link handler a canonical HTTPS web URL.
        // This keeps path/query intact (reel, posts, story.php, permalink.php,
        // groups, watch, share links, profile URLs, etc.) while removing the
        // mobile/mbasic host variants that can otherwise fall back to web.
        url.protocol = "https:";
        url.hostname = "www.facebook.com";
        return url.href;
      }

      return url.href;
    } catch {
      return raw;
    }
  }

  function originalFacebookURL() {
    return normalizeFacebookURL(markerURL() || window.location.href);
  }

  function openInApp() {
    const target = originalFacebookURL();
    const now = Date.now();
    const previous = Number(sessionStorage.getItem(attemptKey()) || 0);
    if (now - previous < 5000) return;

    try {
      sessionStorage.setItem(attemptKey(), String(now));
    } catch {}

    window.location.replace(
      `fb://fbbridge/open?url=${encodeURIComponent(target)}`
    );
  }

  openInApp();
})();
