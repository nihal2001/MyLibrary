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
        anchorPages: [],
        // A requested fraction, kept until the reader moves so relayouts (late
        // images, rotation) round it once at the final page count.
        targetFraction: null,
        // Likewise a requested anchor, re-found after each relayout.
        targetFragment: null,
        ready: false
      };

      function post(message) {
        try { window.webkit.messageHandlers.reader.postMessage(message); } catch (e) {}
      }

      // --- Styling -----------------------------------------------------------
      function injectStyle() {
        // EPUB XHTML rarely declares a viewport, and without one WebKit lays the
        // page out 980px wide and scales it down, leaving the text tiny.
        var head = document.head || document.documentElement;
        var viewport = document.querySelector("meta[name='viewport']");
        if (!viewport) {
          viewport = document.createElement("meta");
          viewport.setAttribute("name", "viewport");
          head.insertBefore(viewport, head.firstChild);
        }
        viewport.setAttribute("content", "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no");

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

      function findTarget(fragment) {
        try {
          return document.getElementById(fragment) ||
                 document.querySelector("[name='" + fragment + "']");
        } catch (e) {
          return null;
        }
      }

      /// Where each table-of-contents anchor in this document starts: a page in
      /// paged mode, a document offset when scrolling.
      function locateAnchors() {
        S.anchorPages = [];
        var anchors = config.anchors || [];
        for (var i = 0; i < anchors.length; i++) {
          var target = findTarget(anchors[i].id);
          if (!target) { continue; }
          var rect = target.getBoundingClientRect();
          var at = S.mode === "scrolling"
            ? rect.top + window.scrollY
            : Math.floor(rect.left / S.stride);
          S.anchorPages.push({ toc: anchors[i].toc, at: at });
        }
      }

      function currentTOC() {
        var here = S.mode === "scrolling" ? window.scrollY + window.innerHeight * 0.3 : S.page;
        var found = -1;
        for (var i = 0; i < S.anchorPages.length; i++) {
          if (S.anchorPages[i].at <= here) { found = S.anchorPages[i].toc; }
        }
        return found;
      }

      function measure() {
        if (S.mode === "scrolling") {
          S.pageCount = 1;
          locateAnchors();
          return;
        }
        S.stride = Math.max(1, window.innerWidth);
        var previous = document.body.style.transform;
        document.body.style.transform = "translateX(0px)";
        var right = contentRight();
        locateAnchors();
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
          toc: currentTOC(),
          spread: isSpread(),
          atStart: S.mode === "scrolling" ? window.scrollY <= 1 : S.page <= 0,
          atEnd: S.mode === "scrolling"
            ? window.scrollY >= scrollExtent() - 1
            : S.page >= S.pageCount - 1
        });
      }

      /// Moves the columns without changing the reader's page; the page curl uses
      /// this to render a neighbouring page, then restores `S.page`.
      S.showPage = function (page) {
        if (S.mode !== "paged") { return; }
        document.body.style.transform = "translateX(" + (-page * S.stride) + "px)";
      };

      function isSpread() {
        if (S.mode !== "paged") { return false; }
        return parseInt(window.getComputedStyle(document.body).columnCount, 10) === 2;
      }

      S.goToPage = function (page, silent) {
        if (S.mode === "scrolling") { return; }
        S.page = Math.min(Math.max(0, Math.round(page)), S.pageCount - 1);
        document.body.style.transform = "translateX(" + (-S.page * S.stride) + "px)";
        if (!silent) { report(); }
      };

      S.goToFraction = function (fraction, silent) {
        var f = Math.min(1, Math.max(0, fraction || 0));
        S.targetFraction = f;
        S.targetFragment = null;
        if (S.mode === "scrolling") {
          window.scrollTo(0, f * scrollExtent());
          if (!silent) { report(); }
        } else {
          S.goToPage(f * (S.pageCount - 1), silent);
        }
      };

      S.goToFragment = function (fragment, silent) {
        var target = findTarget(fragment);
        if (!target) { return false; }
        S.targetFraction = null;
        S.targetFragment = fragment;
        if (S.mode === "scrolling") {
          window.scrollTo(0, target.getBoundingClientRect().top + window.scrollY);
        } else {
          document.body.style.transform = "translateX(0px)";
          var left = target.getBoundingClientRect().left;
          S.goToPage(Math.floor(left / S.stride), true);
        }
        if (!silent) { report(); }
        return true;
      };

      S.next = function () {
        S.targetFraction = null;
        S.targetFragment = null;
        if (S.mode === "scrolling") {
          if (window.scrollY >= scrollExtent() - 1) { post({ type: "edge", direction: "next" }); return; }
          window.scrollBy({ top: window.innerHeight * 0.92, behavior: "instant" });
          report();
        } else {
          // Layout can still grow after the first measurement (fonts, late
          // images), so confirm the last page before leaving the document.
          if (S.page >= S.pageCount - 1) { measure(); }
          if (S.page < S.pageCount - 1) {
            S.goToPage(S.page + 1);
          } else {
            post({ type: "edge", direction: "next" });
          }
        }
      };

      S.previous = function () {
        S.targetFraction = null;
        S.targetFragment = null;
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
          // Left of center, so a two-page spread samples the left page, not the gutter.
          var x = window.innerWidth * 0.25;
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
          if (node.localName === "a") {
            // Links inside the book are handed to Swift, which moves the reader
            // there. Letting WebKit follow them would load the file behind the
            // reader's back and scroll the viewport against the page transform.
            var raw = node.getAttribute("href") ||
                      node.getAttributeNS("http://www.w3.org/1999/xlink", "href");
            var url = null;
            try { url = raw ? new URL(raw, document.baseURI) : null; } catch (e) {}
            if (url && url.protocol === "file:") {
              event.preventDefault();
              post({ type: "link", href: url.href });
            }
            return;
          }
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
        // With the page curl on, Swift owns horizontal drags.
        if (S.mode !== "paged" || config.curl || hasSelection()) { return; }
        var touch = event.changedTouches[0];
        if (!touch) { return; }
        var dx = touch.clientX - touchStartX;
        var dy = touch.clientY - touchStartY;
        if (Date.now() - touchTime > 700) { return; }
        if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          if (dx < 0) { S.next(); } else { S.previous(); }
        }
      }, { passive: true });

      if (S.mode === "paged") {
        // Pages move by transform alone; any scroll (focus, find, a stray
        // fragment jump) would offset the columns and jumble the page.
        window.addEventListener("scroll", function () {
          if (window.scrollX !== 0 || window.scrollY !== 0) { window.scrollTo(0, 0); }
        }, { passive: true });
      }

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
        var fraction = S.targetFraction !== null ? S.targetFraction : S.fraction();
        measure();
        if (!(S.targetFragment && S.goToFragment(S.targetFragment, true))) {
          S.goToFraction(fraction, true);
        }
        report();
      }
      window.addEventListener("resize", function () {
        if (resizeTimer) { clearTimeout(resizeTimer); }
        resizeTimer = setTimeout(relayout, 120);
      });
      window.addEventListener("load", function () { setTimeout(relayout, 0); });
      if (document.fonts && document.fonts.ready) {
        document.fonts.ready.then(function () { setTimeout(relayout, 0); });
      }

      // --- Start -------------------------------------------------------------
      injectStyle();
      measure();
      S.ready = true;
      report("ready");
    })();
    """#
}
