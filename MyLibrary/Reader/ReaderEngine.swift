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
      var config = window.__mlConfig || { css: "", mode: "paged", focus: false };
      var S = window.__ml = {
        mode: config.mode,
        page: 0,
        pageCount: 1,
        stride: 1,
        ready: false,
        focus: {
          enabled: config.focus === true,
          index: -1,
          count: 0,
          prepared: false,
          groups: []
        }
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


      // --- Sentence focus ----------------------------------------------------
      // Apple Books' Line Focus dims the page and lights a single line. This is
      // the same effect with sentences as the unit: every text node is rewritten
      // into spans tagged with a sentence index, so a sentence running through
      // <em> or <a> still lights up as one piece.

      // Titles and abbreviations that end in a period without ending a sentence.
      var ABBREVIATIONS = /(^|[\s("'\u201C\u2018\u00AB\[])(mr|mrs|ms|dr|prof|st|jr|sr|rev|hon|gen|col|capt|lt|sgt|maj|adm|gov|sen|rep|pres|messrs|mt|ft|ave|blvd|rd|vs|etc|al|fig|no|vol|ch|pp|ed|eds|dept|est|approx|inc|ltd|co|corp|univ|e\.g|i\.e|cf|ibid|viz)\.$/i;

      // A single letter and a period is an initial: "J. R. R. Tolkien".
      var INITIAL = /(^|[\s("'\u201C\u2018\u00AB\[])[A-Za-z]\.$/;

      var INLINE_TAGS = {
        a: 1, abbr: 1, b: 1, bdi: 1, bdo: 1, big: 1, br: 1, cite: 1, code: 1,
        data: 1, del: 1, dfn: 1, em: 1, font: 1, i: 1, img: 1, ins: 1, kbd: 1,
        label: 1, mark: 1, q: 1, rp: 1, rt: 1, ruby: 1, s: 1, samp: 1, small: 1,
        span: 1, strike: 1, strong: 1, sub: 1, sup: 1, time: 1, tt: 1, u: 1,
        "var": 1, wbr: 1
      };

      var segmenterCache = null, segmenterLang = null;

      function segmenterFor(lang) {
        if (segmenterLang === lang) { return segmenterCache; }
        segmenterLang = lang;
        segmenterCache = null;
        if (window.Intl && Intl.Segmenter) {
          try { segmenterCache = new Intl.Segmenter(lang, { granularity: "sentence" }); } catch (e) {}
        }
        return segmenterCache;
      }

      function rawSentenceStarts(text, lang) {
        var segmenter = segmenterFor(lang);
        if (segmenter) {
          try {
            var iterator = segmenter.segment(text)[Symbol.iterator]();
            var starts = [], step = iterator.next();
            while (!step.done) { starts.push(step.value.index); step = iterator.next(); }
            if (starts.length) { return starts; }
          } catch (e) {}
        }
        var pattern = /[.!?\u2026\u3002\uFF01\uFF1F]+["'\u201D\u2019)\]]*(\s+|$)/g;
        var result = [0], match;
        while ((match = pattern.exec(text)) !== null) {
          var next = match.index + match[0].length;
          if (next < text.length) { result.push(next); }
          if (pattern.lastIndex <= match.index) { pattern.lastIndex = match.index + 1; }
        }
        return result;
      }

      // Unicode sentence breaking knows nothing about abbreviations, so it splits
      // "Mr. Smith" in two and cuts '"Stop!" she cried.' after the quote. Both
      // read badly one sentence at a time, so those breaks are merged back.
      function continuesSentence(before, after) {
        var head = after.replace(/^[\s"'\u201C\u2018(\[]+/, "").charAt(0);
        if (head && head === head.toLowerCase() && head !== head.toUpperCase()) { return true; }
        var tail = before.replace(/\s+$/, "");
        return INITIAL.test(tail) || ABBREVIATIONS.test(tail);
      }

      function sentenceStarts(text, lang) {
        var raw = rawSentenceStarts(text, lang);
        if (raw.length <= 1) { return raw; }

        var kept = [raw[0]];
        for (var i = 1; i < raw.length; i++) {
          var at = raw[i];
          if (continuesSentence(text.slice(kept[kept.length - 1], at), text.slice(at))) { continue; }
          kept.push(at);
        }

        var merged = [];
        for (var k = 0; k < kept.length; k++) {
          var end = (k + 1 < kept.length) ? kept[k + 1] : text.length;
          // Never drop the first start: the wrapper assumes offset 0 is covered.
          if (merged.length && !text.slice(kept[k], end).trim()) { continue; }
          merged.push(kept[k]);
        }
        return merged;
      }

      function blockAncestor(node) {
        var element = node.parentNode;
        while (element && element !== document.body && element.nodeType === 1 &&
               INLINE_TAGS[element.nodeName.toLowerCase()]) {
          element = element.parentNode;
        }
        return element || document.body;
      }

      // Rewrites one block's text nodes into sentence spans. Both the node ranges
      // and the sentence ranges ascend, so the segment cursor only moves forward.
      function wrapBlock(nodes, startIndex, lang) {
        var combined = "", offsets = [], i;
        for (i = 0; i < nodes.length; i++) {
          offsets.push(combined.length);
          combined += nodes[i].nodeValue;
        }
        if (!combined.trim()) { return startIndex; }

        var starts = sentenceStarts(combined, lang), cursor = 0;

        for (var n = 0; n < nodes.length; n++) {
          var text = nodes[n].nodeValue, from = offsets[n], to = from + text.length;
          var parent = nodes[n].parentNode;
          if (!parent) { continue; }

          var fragment = document.createDocumentFragment(), made = 0;
          while (cursor + 1 < starts.length && starts[cursor + 1] <= from) { cursor++; }

          for (var k = cursor; k < starts.length; k++) {
            var segStart = starts[k];
            var segEnd = (k + 1 < starts.length) ? starts[k + 1] : combined.length;
            if (segStart >= to) { break; }
            if (segEnd <= from) { continue; }
            var slice = text.slice(Math.max(segStart, from) - from, Math.min(segEnd, to) - from);
            if (!slice) { continue; }

            var id = startIndex + k;
            var span = document.createElement("span");
            span.className = "ml-s";
            span.setAttribute("data-ml-s", String(id));
            span.appendChild(document.createTextNode(slice));
            fragment.appendChild(span);
            (S.focus.groups[id] = S.focus.groups[id] || []).push(span);
            made++;
          }
          if (made) { parent.replaceChild(fragment, nodes[n]); }
        }
        return startIndex + starts.length;
      }

      function prepareSentences() {
        if (S.focus.prepared) { return; }
        S.focus.prepared = true;

        var lang = document.documentElement.getAttribute("lang") ||
                   document.body.getAttribute("lang") || config.lang || "en";

        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            var parent = node.parentNode;
            if (!parent) { return NodeFilter.FILTER_REJECT; }
            var tag = parent.nodeName.toLowerCase();
            if (tag === "script" || tag === "style" || tag === "noscript") {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });

        // Collect every text node first: the walk has to finish before the DOM
        // is rewritten underneath it.
        var blocks = [], current = null, lastBlock = null, node;
        while ((node = walker.nextNode())) {
          var block = blockAncestor(node);
          if (block !== lastBlock) { current = []; blocks.push(current); lastBlock = block; }
          current.push(node);
        }

        var index = 0;
        for (var b = 0; b < blocks.length; b++) { index = wrapBlock(blocks[b], index, lang); }

        // A segment can come out whitespace-only and produce no spans; drop those
        // so the index space has no holes to get stuck on.
        var compact = [];
        for (var g = 0; g < S.focus.groups.length; g++) {
          var spans = S.focus.groups[g];
          if (!spans || !spans.length) { continue; }
          var visible = "";
          for (var v = 0; v < spans.length; v++) { visible += spans[v].textContent; }
          if (!visible.trim()) { continue; }
          for (var j = 0; j < spans.length; j++) {
            spans[j].setAttribute("data-ml-s", String(compact.length));
          }
          compact.push(spans);
        }
        S.focus.groups = compact;
        S.focus.count = compact.length;
      }

      function firstRect(element) {
        var rects = element.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          if (rects[i].width > 0 || rects[i].height > 0) { return rects[i]; }
        }
        return element.getBoundingClientRect();
      }

      function revealSpan(span) {
        var rect = firstRect(span);
        if (S.mode === "scrolling") {
          if (rect.top < 0 || rect.bottom > window.innerHeight) {
            window.scrollTo(0, Math.max(0, rect.top + window.scrollY - window.innerHeight * 0.3));
          }
        } else {
          // The rect is post-transform, so add the current offset back to recover
          // the sentence's absolute x, and from that the page holding it.
          var target = Math.floor((rect.left + S.page * S.stride) / S.stride);
          if (target !== S.page) { S.goToPage(target, true); }
        }
      }

      S.focusSentence = function (index, silent) {
        if (!S.focus.count) { return; }
        index = Math.min(Math.max(0, Math.round(index)), S.focus.count - 1);

        var previous = S.focus.groups[S.focus.index];
        if (previous) {
          for (var i = 0; i < previous.length; i++) { previous[i].classList.remove("ml-on"); }
        }

        S.focus.index = index;
        var spans = S.focus.groups[index];
        if (!spans) { return; }
        for (var j = 0; j < spans.length; j++) { spans[j].classList.add("ml-on"); }
        revealSpan(spans[0]);
        if (!silent) { report(); }
      };

      // Picks the sentence to light after a page jump: the first one that starts
      // on the page now showing.
      S.syncFocusToPage = function (preferLast) {
        if (!S.focus.enabled || !S.focus.count) { return; }
        if (preferLast) { S.focusSentence(S.focus.count - 1, true); return; }
        for (var i = 0; i < S.focus.count; i++) {
          var spans = S.focus.groups[i];
          if (!spans || !spans.length) { continue; }
          var rect = firstRect(spans[0]);
          if (S.mode === "scrolling" ? rect.bottom >= 0 : rect.left >= -2) {
            S.focusSentence(i, true);
            return;
          }
        }
        S.focusSentence(0, true);
      };

      S.setFocusMode = function (enabled) {
        S.focus.enabled = enabled === true;
        if (S.focus.enabled) {
          prepareSentences();
          measure();      // wrapping text in spans can nudge the column count
          document.documentElement.classList.add("ml-focus-mode");
          if (S.focus.index >= 0) { S.focusSentence(S.focus.index, true); }
          else { S.syncFocusToPage(false); }
        } else {
          document.documentElement.classList.remove("ml-focus-mode");
        }
        report();
      };

      S.nextSentence = function () {
        if (S.focus.index >= S.focus.count - 1) { post({ type: "edge", direction: "next" }); return; }
        S.focusSentence(S.focus.index + 1);
      };

      S.previousSentence = function () {
        if (S.focus.index <= 0) { post({ type: "edge", direction: "previous" }); return; }
        S.focusSentence(S.focus.index - 1);
      };

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
            : S.page >= S.pageCount - 1,
          focus: S.focus.enabled,
          sentence: S.focus.index,
          sentenceCount: S.focus.count
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
        } else {
          S.goToPage(f * (S.pageCount - 1), true);
        }
        // Entering a document backwards lands on its last sentence.
        S.syncFocusToPage(f >= 0.999);
        if (!silent) { report(); }
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
        S.syncFocusToPage(false);
        report();
        return true;
      };

      S.next = function () {
        if (S.focus.enabled && S.focus.count) { S.nextSentence(); return; }
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
        if (S.focus.enabled && S.focus.count) { S.previousSentence(); return; }
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

      /// Text for a bookmark preview: the focused sentence when there is one,
      /// otherwise whatever sits near the top of the page.
      S.snippet = function () {
        if (S.focus.enabled) {
          var spans = S.focus.groups[S.focus.index];
          if (spans && spans.length) {
            var sentence = "";
            for (var i = 0; i < spans.length; i++) { sentence += spans[i].textContent; }
            sentence = sentence.replace(/\s+/g, " ").trim();
            if (sentence) {
              return sentence.length > 180 ? sentence.slice(0, 180) + "\u2026" : sentence;
            }
          }
        }
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
        if (S.focus.enabled && S.focus.index >= 0) {
          measure();
          S.focusSentence(S.focus.index, true);
          report();
          return;
        }
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
      if (S.focus.enabled) {
        prepareSentences();
        measure();
        document.documentElement.classList.add("ml-focus-mode");
        S.focusSentence(0, true);
      }
      S.ready = true;
      report("ready");
    })();
    """#
}
