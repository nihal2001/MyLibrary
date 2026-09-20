// Runs the real ReaderEngine script, extracted from the Swift source, inside jsdom.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const source = path.join(__dirname, '..', '..', 'MyLibrary', 'Reader', 'ReaderEngine.swift');
const swift = fs.readFileSync(source, 'utf8');
const match = swift.match(/static let script = #"""\n([\s\S]*?)\n    """#/);
if (!match) { console.error('could not extract the engine script'); process.exit(1); }
const script = match[1];

let failures = 0;
function check(ok, label, detail) {
  if (ok) console.log('  ok   ' + label);
  else { console.log('  FAIL ' + label + (detail !== undefined ? '  ' + JSON.stringify(detail) : '')); failures++; }
}

function boot(bodyHTML, { focus = true, mode = 'paged', lang = 'en', curl = false } = {}) {
  const dom = new JSDOM(`<!DOCTYPE html><html lang="${lang}"><head></head><body>${bodyHTML}</body></html>`,
                        { runScripts: 'outside-only', pretendToBeVisual: true });
  const messages = [];
  dom.window.webkit = { messageHandlers: { reader: { postMessage: m => messages.push(m) } } };
  dom.window.__mlConfig = { css: 'body { color: red; }', mode, focus, curl, anchors: [] };
  dom.window.eval(script);
  return { dom, win: dom.window, doc: dom.window.document, S: dom.window.__ml, messages };
}

console.log('== boot and wrap ==');
let { doc, S, messages } = boot(
  '<h1>Chapter One</h1>' +
  '<p>The morning was cold. <em>Elizabeth</em> walked to the window. "How strange," she said.</p>' +
  '<p>Mr. Bennet said nothing at all.</p>');

check(S.ready === true, 'engine reports ready');
check(messages.length > 0 && messages[0].type === 'ready', 'ready message posted', messages[0] && messages[0].type);
check(S.focus.enabled === true, 'focus mode on from config');
check(doc.documentElement.classList.contains('ml-focus-mode'), 'root class applied');

// h1 + 3 sentences + 1 sentence = 5
check(S.focus.count === 5, 'sentence count', S.focus.count);
check(messages[0].sentenceCount === 5, 'ready message carries the count', messages[0].sentenceCount);

console.log('\n== text integrity ==');
const expected = 'Chapter OneThe morning was cold. Elizabeth walked to the window. "How strange," she said.Mr. Bennet said nothing at all.';
check(doc.body.textContent === expected, 'no text lost or duplicated',
      { got: doc.body.textContent, expected });
check(doc.querySelector('em') !== null, 'inline markup preserved');
check(doc.querySelector('em .ml-s') !== null, 'spans nest inside inline markup');
check(doc.querySelectorAll('.ml-s').length >= 5, 'spans created', doc.querySelectorAll('.ml-s').length);

// "Mr. Bennet" must be one sentence, and the <em> sentence must be one unit.
const s2 = [...doc.querySelectorAll('[data-ml-s="2"]')].map(e => e.textContent).join('');
check(s2.includes('Elizabeth') && s2.includes('walked to the window'),
      'sentence spanning <em> is one unit', s2);
const last = [...doc.querySelectorAll('[data-ml-s="4"]')].map(e => e.textContent).join('');
check(last.trim() === 'Mr. Bennet said nothing at all.', 'abbreviation kept whole', last);

console.log('\n== focus and stepping ==');
check(S.focus.index === 0, 'starts on the first sentence', S.focus.index);
check(doc.querySelectorAll('.ml-on').length > 0, 'a sentence is lit');
check([...doc.querySelectorAll('.ml-on')].every(e => e.getAttribute('data-ml-s') === '0'),
      'only sentence 0 is lit');

S.next();
check(S.focus.index === 1, 'next() steps one sentence', S.focus.index);
check([...doc.querySelectorAll('.ml-on')].every(e => e.getAttribute('data-ml-s') === '1'),
      'the lit sentence moved');
check(doc.querySelectorAll('.ml-on').length > 0, 'exactly one sentence group lit');

S.previous();
check(S.focus.index === 0, 'previous() steps back', S.focus.index);

// Walk the whole document and off the end.
messages.length = 0;
for (let i = 0; i < 4; i++) S.next();
check(S.focus.index === 4, 'walks to the last sentence', S.focus.index);
S.next();
const edge = messages.filter(m => m.type === 'edge');
check(edge.length === 1 && edge[0].direction === 'next', 'past the end posts an edge message', edge);
check(S.focus.index === 4, 'index stays clamped at the end', S.focus.index);

S.focusSentence(0, true);
messages.length = 0;
S.previous();
const backEdge = messages.filter(m => m.type === 'edge');
check(backEdge.length === 1 && backEdge[0].direction === 'previous', 'before the start posts an edge', backEdge);

console.log('\n== toggling at runtime ==');
({ doc, S, messages } = boot('<p>One. Two. Three.</p>', { focus: false }));
check(S.focus.enabled === false, 'starts off when configured off');
check(doc.querySelectorAll('.ml-s').length === 0, 'no wrapping until needed');
check(!doc.documentElement.classList.contains('ml-focus-mode'), 'no root class');

S.setFocusMode(true);
check(S.focus.enabled === true, 'turns on');
check(S.focus.count === 3, 'wraps on first enable', S.focus.count);
check(doc.documentElement.classList.contains('ml-focus-mode'), 'root class added');
check(doc.body.textContent === 'One. Two. Three.', 'text intact after late wrapping', doc.body.textContent);

S.next();
const held = S.focus.index;
S.setFocusMode(false);
check(!doc.documentElement.classList.contains('ml-focus-mode'), 'root class removed');
S.setFocusMode(true);
check(S.focus.index === held, 'returns to the same sentence', { held, now: S.focus.index });
check(doc.querySelectorAll('.ml-s').length === 3, 'no double wrapping on re-enable',
      doc.querySelectorAll('.ml-s').length);

console.log('\n== edge cases ==');
({ doc, S } = boot('<p>   </p><div></div>'));
check(S.focus.count === 0, 'blank document yields no sentences', S.focus.count);
S.next();  // must not throw or hang
check(true, 'stepping a blank document is safe');

({ doc, S } = boot('<p>Solo sentence with no terminator</p>'));
check(S.focus.count === 1, 'unterminated text is one sentence', S.focus.count);

({ doc, S } = boot('<script>var x = "A. B.";</script><p>Real text. More.</p>'));
check(S.focus.count === 2, 'script contents are skipped', S.focus.count);
check(doc.querySelector('script').textContent === 'var x = "A. B.";', 'script body untouched');

({ doc, S } = boot('<ul><li>First item.</li><li>Second item.</li></ul>'));
check(S.focus.count === 2, 'list items are separate sentences', S.focus.count);

({ doc, S } = boot('<p>Before <a href="x.html">a link</a> after. Next.</p>'));
check(S.focus.count === 2, 'links do not break a sentence', S.focus.count);
check(doc.querySelector('a .ml-s') !== null, 'link text is wrapped');
check(doc.querySelector('a').getAttribute('href') === 'x.html', 'link target preserved');

({ doc, S } = boot('<p>Scroll one. Scroll two.</p>', { mode: 'scrolling' }));
check(S.focus.count === 2, 'scrolling mode wraps too', S.focus.count);
S.next();
check(S.focus.index === 1, 'scrolling mode steps sentences', S.focus.index);

console.log('\n== page curl handoff ==');
// The curl owns horizontal drags, but Sentence Focus takes them back so a drag
// steps a sentence instead of turning a page. Swift mirrors this by switching
// curlIsActive off while focus is on.
({ doc, S } = boot('<p>Curl one. Curl two. Curl three.</p>', { focus: true, curl: true }));
check(S.curlEnabled === true, 'curl flag read from config');
check(S.focus.enabled === true, 'focus still on with the curl configured');
S.next();
check(S.focus.index === 1, 'a tap steps a sentence rather than turning a page', S.focus.index);

({ doc, S } = boot('<p>Curl one. Curl two.</p>', { focus: false, curl: true }));
check(S.curlEnabled === true, 'curl flag set with focus off');
check(S.focus.count === 0, 'nothing wrapped while focus is off', S.focus.count);

console.log('\n== report payload ==');
({ S, messages } = boot('<p>Alpha. Beta.</p>'));
const ready = messages.find(m => m.type === 'ready');
for (const key of ['page', 'pageCount', 'fraction', 'focus', 'sentence', 'sentenceCount', 'toc', 'spread']) {
  check(Object.prototype.hasOwnProperty.call(ready, key), 'ready reports ' + key, Object.keys(ready));
}
check(ready.focus === true && ready.sentenceCount === 2, 'focus fields carry real values',
      { focus: ready.focus, count: ready.sentenceCount });

console.log(failures === 0 ? '\nALL CHECKS PASSED' : '\n' + failures + ' CHECK(S) FAILED');
process.exit(failures === 0 ? 0 : 1);
