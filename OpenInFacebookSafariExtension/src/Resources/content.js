// "Open in Facebook" — content script.
//
// Runs on facebook.com (and fb.* short domains) pages loaded in Safari and sends
// the viewer into the sideloaded Facebook app through its fb:// URL scheme.
//
// Resolution order for the native destination:
//   1. the app link Facebook advertises in <meta property="al:ios:url"> (fb://…)
//   2. the Smart App Banner's app-argument in <meta name="apple-itunes-app">
//   3. a generic fallback that reopens the current page inside the app:
//        fb://facewebmodal/f?href=<current url>
//
// A short-lived sessionStorage guard prevents a redirect loop if iOS bounces the
// viewer back to the same Safari page.

(() => {
  "use strict";

  const currentURL = () => new URL(window.location.href);
  const attemptKey = () => `open-in-facebook:${window.location.href}`;

  function fbURLFromMeta(selector, attribute) {
    const value = document.querySelector(selector)?.getAttribute(attribute);
    return value && value.startsWith("fb://") ? value : null;
  }

  function appArgumentURL() {
    const banner = document
      .querySelector('meta[name="apple-itunes-app"]')
      ?.getAttribute("content");
    const encoded = banner?.match(/(?:^|,\s*)app-argument=([^,]+)/)?.[1];
    if (!encoded) return null;
    try {
      const argument = decodeURIComponent(encoded);
      return argument.startsWith("fb://") ? argument : null;
    } catch {
      return null;
    }
  }

  // google.js stashes the clean Facebook URL it was sent from in the fragment,
  // because fragments survive HTTP redirects and are never sent to the server.
  function markerURL() {
    const marker = currentURL().hash.match(/(?:^#|&)open-in-facebook=([^&]+)/)?.[1];
    if (!marker) return null;
    try {
      return decodeURIComponent(marker);
    } catch {
      return null;
    }
  }

  function genericFallback() {
    const href = markerURL() || window.location.href;
    return `fb://facewebmodal/f?href=${encodeURIComponent(href)}`;
  }

  function nativeDestination() {
    return (
      fbURLFromMeta('meta[property="al:ios:url"]', "content") ||
      appArgumentURL() ||
      genericFallback()
    );
  }

  function diagnosticSnapshot() {
    const alIOS = fbURLFromMeta('meta[property="al:ios:url"]', "content");
    const appArg = appArgumentURL();
    const marker = markerURL();
    const fallback = genericFallback();
    const destination = alIOS || appArg || fallback;
    const source = alIOS ? "al:ios:url" : appArg ? "app-argument" : "fallback";
    return {
      page: window.location.href,
      alIOS: alIOS || "(none)",
      appArg: appArg || "(none)",
      marker: marker || "(none)",
      fallback,
      source,
      destination
    };
  }

  function showDiagnostic(info) {
    const message = [
      "Open in Facebook — DEBUG",
      "",
      `SOURCE: ${info.source}`,
      "",
      `PAGE:\n${info.page}`,
      "",
      `al:ios:url:\n${info.alIOS}`,
      "",
      `app-argument:\n${info.appArg}`,
      "",
      `marker:\n${info.marker}`,
      "",
      `FINAL:\n${info.destination}`,
      "",
      "OK = open FINAL in Facebook",
      "Cancel = stay in Safari so you can screenshot/copy this dialog"
    ].join("\n");
    return window.confirm(message);
  }

  function openInApp() {
    const info = diagnosticSnapshot();
    if (!info.destination) return false;

    const now = Date.now();
    const previous = Number(sessionStorage.getItem(attemptKey()) || 0);
    if (now - previous < 5000) return true;

    try {
      sessionStorage.setItem(attemptKey(), String(now));
    } catch {}

    if (!showDiagnostic(info)) {
      try { sessionStorage.removeItem(attemptKey()); } catch {}
      return true;
    }

    window.location.replace(info.destination);
    return true;
  }

  if (openInApp()) return;

  // Facebook injects some of its metadata after first paint; watch briefly for a
  // better (app-link) destination, then give up.
  const observer = new MutationObserver(() => {
    if (fbURLFromMeta('meta[property="al:ios:url"]', "content") || appArgumentURL()) {
      observer.disconnect();
      openInApp();
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 5000);
})();
