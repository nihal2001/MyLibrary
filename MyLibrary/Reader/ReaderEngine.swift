import Foundation

/// The JavaScript that paginates a document inside the reader's web view.
///
/// It reads its configuration from `window.__mlConfig`, which Swift injects
/// immediately before this script, then reports position changes and taps back
/// over the `reader` message handler.
enum ReaderEngine {

    static let script = #"""
    (function () {
      "use strict";
      var config = window.__mlConfig || { css: "", mode: "paged" };
      var S = window.__ml = {
        mode: config.mode,
        page: 0,
        pageCount: 1,
        stride: 1,
        ready: false
      };

      function post(message) {
        try { window.webkit.messageHandlers.reader.postMessage(message); } catch (e) {}
      }

      // --- Styling -----------------------------------------------------------
      function injectStyle() {
        var existing = document.getElementById("ml-style");
        if (existing) { existing.parentNode.removeChild(existing); }
        var style = document.createElement("style");
        style.id = "ml-style";
        style.textContent = config.css;
        (document.head || document.documentElement).appendChild(style);
      }

      // --- Measurement -------------------------------------------------------
      function contentRight() {
        // A range over the body reports one rect per column, so the last rect's
        // right edge is the true end of the content.
        try {
          var range = document.createRange();
          range.selectNodeContents(document.body);
          var rects = range.getClientRects();
          if (rects && rects.length) {
            var max = 0;
            for (var i = 0; i < rects.length; i++) {
              if (rects[i].width > 0 || rects[i].height > 0) {
                max = Math.max(max, rects[i].right);
              }
            }
            if (max > 0) { return max; }
          }
        } catch (e) {}
        return document.body.scrollWidth;
      }

      function measure() {
        if (S.mode === "scrolling") {
          S.pageCount = 1;
          return;
        }
        S.stride = Math.max(1, window.innerWidth);
        var previous = document.body.style.transform;
        document.body.style.transform = "translateX(0px)";
        var right = contentRight();
        document.body.style.transform = previous;
        S.pageCount = Math.max(1, Math.ceil((right - 1) / S.stride));
      }

      // --- Position ----------------------------------------------------------
      function scrollExtent() {
        return Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
      }

      S.fraction = function () {
        if (S.mode === "scrolling") {
          return Math.min(1, Math.max(0, window.scrollY / scrollExtent()));
        }
        return S.pageCount > 1 ? S.page / (S.pageCount - 1) : 0;
      };

      function report(type) {
        post({
          type: type || "position",
          page: S.page,
          pageCount: S.pageCount,
          fraction: S.fraction(),
          atStart: S.mode === "scrolling" ? window.scrollY <= 1 : S.page <= 0,
          atEnd: S.mode === "scrolling"
            ? window.scrollY >= scrollExtent() - 1
            : S.page >= S.pageCount - 1
        });
      }

      S.goToPage = function (page, silent) {
        if (S.mode === "scrolling") { return; }
        S.page = Math.min(Math.max(0, Math.round(page)), S.pageCount - 1);
        document.body.style.transform = "translateX(" + (-S.page * S.stride) + "px)";
        if (!silent) { report(); }
      };

      S.goToFraction = function (fraction, silent) {
        var f = Math.min(1, Math.max(0, fraction || 0));
        if (S.mode === "scrolling") {
          window.scrollTo(0, f * scrollExtent());
          if (!silent) { report(); }
        } else {
          S.goToPage(f * (S.pageCount - 1), silent);
        }
      };

      S.goToFragment = function (fragment) {
        var target = null;
        try {
          target = document.getElementById(fragment) ||
                   document.querySelector("[name='" + fragment + "']");
        } catch (e) {}
        if (!target) { return false; }
        if (S.mode === "scrolling") {
          window.scrollTo(0, target.getBoundingClientRect().top + window.scrollY);
        } else {
          document.body.style.transform = "translateX(0px)";
          var left = target.getBoundingClientRect().left;
          S.goToPage(Math.floor(left / S.stride), true);
        }
        report();
        return true;
      };

      S.next = function () {
        if (S.mode === "scrolling") {
          if (window.scrollY >= scrollExtent() - 1) { post({ type: "edge", direction: "next" }); return; }
          window.scrollBy({ top: window.innerHeight * 0.92, behavior: "instant" });
          report();
        } else if (S.page < S.pageCount - 1) {
          S.goToPage(S.page + 1);
        } else {
          post({ type: "edge", direction: "next" });
        }
      };

      S.previous = function () {
        if (S.mode === "scrolling") {
          if (window.scrollY <= 1) { post({ type: "edge", direction: "previous" }); return; }
          window.scrollBy({ top: -window.innerHeight * 0.92, behavior: "instant" });
          report();
        } else if (S.page > 0) {
          S.goToPage(S.page - 1);
        } else {
          post({ type: "edge", direction: "previous" });
        }
      };

      /// Text near the top of the current page, used as a bookmark preview.
      S.snippet = function () {
        try {
          var x = S.mode === "paged" ? window.innerWidth * 0.5 : window.innerWidth * 0.5;
          var y = window.innerHeight * 0.12;
          var range = document.caretRangeFromPoint(x, y);
          var node = range ? range.startContainer : null;
          var element = node ? (node.nodeType === 3 ? node.parentElement : node) : document.body;
          var text = (element && element.textContent) ? element.textContent : "";
          text = text.replace(/\s+/g, " ").trim();
          return text.length > 180 ? text.slice(0, 180) + "…" : text;
        } catch (e) {
          return "";
        }
      };

      // --- Input -------------------------------------------------------------
      function hasSelection() {
        var selection = window.getSelection();
        return selection && selection.toString().length > 0;
      }

      document.addEventListener("click", function (event) {
        if (hasSelection()) { return; }
        var node = event.target;
        while (node) {
          if (node.tagName && node.tagName.toLowerCase() === "a") { return; }
          node = node.parentElement;
        }
        var third = window.innerWidth / 3;
        var zone = event.clientX < third ? "left" : (event.clientX > third * 2 ? "right" : "center");
        post({ type: "tap", zone: zone });
      }, false);

      var touchStartX = 0, touchStartY = 0, touchTime = 0;
      document.addEventListener("touchstart", function (event) {
        if (event.touches.length !== 1) { return; }
        touchStartX = event.touches[0].clientX;
        touchStartY = event.touches[0].clientY;
        touchTime = Date.now();
      }, { passive: true });

      document.addEventListener("touchend", function (event) {
        if (S.mode !== "paged" || hasSelection()) { return; }
        var touch = event.changedTouches[0];
        if (!touch) { return; }
        var dx = touch.clientX - touchStartX;
        var dy = touch.clientY - touchStartY;
        if (Date.now() - touchTime > 700) { return; }
        if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          if (dx < 0) { S.next(); } else { S.previous(); }
        }
      }, { passive: true });

      if (S.mode === "scrolling") {
        var scrollTimer = null;
        window.addEventListener("scroll", function () {
          if (scrollTimer) { clearTimeout(scrollTimer); }
          scrollTimer = setTimeout(function () { report(); }, 120);
        }, { passive: true });
      }

      // Re-measure on rotation, split-view resize, and late-loading images.
      var resizeTimer = null;
      function relayout() {
        var fraction = S.fraction();
        measure();
        S.goToFraction(fraction, true);
        report();
      }
      window.addEventListener("resize", function () {
        if (resizeTimer) { clearTimeout(resizeTimer); }
        resizeTimer = setTimeout(relayout, 120);
      });
      window.addEventListener("load", function () { setTimeout(relayout, 0); });

      // --- Start -------------------------------------------------------------
      injectStyle();
      measure();
      S.ready = true;
      report("ready");
    })();
    """#
}
