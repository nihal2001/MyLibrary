// Prototype of the sentence-splitting core that will live in ReaderEngine.
// Pure data in, pure data out, so it can be tested without a DOM.

// Titles and abbreviations that end in a period without ending a sentence.
var ABBREVIATIONS = /(^|[\s("'\u201C\u2018\u00AB\[])(mr|mrs|ms|dr|prof|st|jr|sr|rev|hon|gen|col|capt|lt|sgt|maj|adm|gov|sen|rep|pres|messrs|mt|ft|ave|blvd|rd|vs|etc|al|fig|no|vol|ch|pp|ed|eds|dept|est|approx|inc|ltd|co|corp|univ|e\.g|i\.e|cf|ibid|viz)\.$/i;

// A single letter followed by a period is an initial: "J. R. R. Tolkien".
var INITIAL = /(^|[\s("'\u201C\u2018\u00AB\[])[A-Za-z]\.$/;

function rawStarts(text, lang) {
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    try {
      var segmenter = new Intl.Segmenter(lang || "en", { granularity: "sentence" });
      var iterator = segmenter.segment(text)[Symbol.iterator]();
      var starts = [], step = iterator.next();
      while (!step.done) { starts.push(step.value.index); step = iterator.next(); }
      if (starts.length) { return starts; }
    } catch (e) {}
  }
  // Fallback for engines without Intl.Segmenter: break after terminators.
  var pattern = /[.!?…。！？]+["'”’)\]]*(\s+|$)/g;
  var result = [0], match;
  while ((match = pattern.exec(text)) !== null) {
    var next = match.index + match[0].length;
    if (next < text.length) { result.push(next); }
    if (pattern.lastIndex <= match.index) { pattern.lastIndex = match.index + 1; }
  }
  return result;
}

// Unicode sentence breaking has no notion of abbreviations, so it splits
// "Mr. Smith" in two and cuts '"Stop!" she cried.' after the quote. Both read
// badly one sentence at a time, so candidate breaks are merged back when the
// text around them says the sentence is still going.
function continuesSentence(before, after) {
  var head = after.replace(/^[\s"'“‘(\[]+/, "").charAt(0);
  // A lowercase letter after the break means the sentence carries on.
  if (head && head === head.toLowerCase() && head !== head.toUpperCase()) { return true; }
  var tail = before.replace(/\s+$/, "");
  return INITIAL.test(tail) || ABBREVIATIONS.test(tail);
}

function sentenceStarts(text, lang) {
  var raw = rawStarts(text, lang);
  if (raw.length <= 1) { return raw; }
  var kept = [raw[0]];
  for (var i = 1; i < raw.length; i++) {
    var at = raw[i];
    if (continuesSentence(text.slice(kept[kept.length - 1], at), text.slice(at))) { continue; }
    kept.push(at);
  }
  return kept;
}

// texts: the text-node strings of one block, in document order.
// Returns one array of {sentence, text} pieces per node, plus the next free
// index. A node with no pieces is left untouched in the DOM.
function planGroup(texts, startIndex, lang) {
  var combined = "", offsets = [];
  for (var i = 0; i < texts.length; i++) {
    offsets.push(combined.length);
    combined += texts[i];
  }
  if (!combined.trim()) {
    return { pieces: texts.map(function () { return []; }), next: startIndex };
  }

  var starts = sentenceStarts(combined, lang);
  var pieces = [], cursor = 0;

  for (var n = 0; n < texts.length; n++) {
    var from = offsets[n], to = from + texts[n].length, list = [];
    // Both node ranges and sentence ranges ascend, so the cursor only moves forward.
    while (cursor + 1 < starts.length && starts[cursor + 1] <= from) { cursor++; }
    for (var k = cursor; k < starts.length; k++) {
      var segStart = starts[k];
      var segEnd = (k + 1 < starts.length) ? starts[k + 1] : combined.length;
      if (segStart >= to) { break; }
      if (segEnd <= from) { continue; }
      var slice = texts[n].slice(Math.max(segStart, from) - from, Math.min(segEnd, to) - from);
      if (slice) { list.push({ sentence: startIndex + k, text: slice }); }
    }
    pieces.push(list);
  }
  return { pieces: pieces, next: startIndex + starts.length };
}

module.exports = { sentenceStarts: sentenceStarts, planGroup: planGroup };
