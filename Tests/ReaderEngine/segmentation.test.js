const { sentenceStarts, planGroup } = require('./core.js');

let failures = 0;
function check(ok, label, detail) {
  if (ok) { console.log('  ok   ' + label); }
  else { console.log('  FAIL ' + label + (detail !== undefined ? '  ' + JSON.stringify(detail) : '')); failures++; }
}
function flat(plan) {
  return plan.pieces.map(list => list.map(p => [p.sentence, p.text]));
}

console.log('== segmentation ==');
const s1 = sentenceStarts('One. Two! Three?', 'en');
check(s1.length === 3, 'three sentences', s1);
check(s1[0] === 0, 'starts at zero', s1);

const abbrev = sentenceStarts('Mr. Smith went home. He slept.', 'en');
check(abbrev.length === 2, 'abbreviation does not split', abbrev);

const quoted = sentenceStarts('"Stop!" she cried. Then silence.', 'en');
check(quoted.length === 2, 'quoted exclamation stays with its sentence', quoted);

const none = sentenceStarts('no terminator here', 'en');
check(none.length === 1 && none[0] === 0, 'single unterminated sentence', none);

console.log('\n== node mapping ==');
// A sentence that runs across three text nodes (as <em> would produce).
let plan = planGroup(['Hello ', 'brave', ' world. Next one.'], 0, 'en');
let f = flat(plan);
check(f[0].length === 1 && f[0][0][0] === 0, 'node 0 belongs to sentence 0', f[0]);
check(f[1].length === 1 && f[1][0][0] === 0, 'node 1 belongs to sentence 0', f[1]);
check(f[2].length === 2 && f[2][0][0] === 0 && f[2][1][0] === 1, 'node 2 splits across the boundary', f[2]);
check(plan.next === 2, 'two sentences consumed', plan.next);

// Text must survive the split exactly.
function roundTrip(texts, label) {
  const p = planGroup(texts, 0, 'en');
  // A node with no pieces is left untouched in the DOM, so it still contributes
  // its original text to the page.
  const rebuilt = p.pieces.map((list, i) => list.length ? list.map(x => x.text).join('') : texts[i]).join('');
  check(rebuilt === texts.join(''), 'round-trip preserves text: ' + label,
        { expected: texts.join(''), got: rebuilt });
  p.pieces.forEach((list, i) => {
    if (!list.length) { check(!texts[i].trim(), 'unwrapped node is blank: ' + label, texts[i]); }
  });
  // Indices must be contiguous and ascending.
  const seen = [];
  p.pieces.forEach(list => list.forEach(x => { if (seen[seen.length - 1] !== x.sentence) seen.push(x.sentence); }));
  const ascending = seen.every((v, i) => i === 0 || v >= seen[i - 1]);
  check(ascending, 'indices ascend: ' + label, seen);
  const max = seen.length ? Math.max(...seen) : -1;
  check(max < p.next, 'indices stay below next: ' + label, { max, next: p.next });
}

roundTrip(['Hello ', 'brave', ' world. Next one.'], 'across nodes');
roundTrip(['One. ', 'Two. ', 'Three.'], 'boundary at every node edge');
roundTrip(['A very long sentence with no end'], 'unterminated');
roundTrip(['   ', '\n\t '], 'whitespace only');
roundTrip(['', 'Text after an empty node. More.'], 'empty leading node');
roundTrip(['Dr. Who said "Run!" and ran. ', 'Then he stopped.'], 'abbreviation and quotes');
roundTrip(['Ellipsis… then more. ', 'End.'], 'ellipsis');
roundTrip(['日本語。次の文。'], 'CJK terminators');

// Whitespace-only groups produce no spans at all (nothing visible to dim).
plan = planGroup(['  \n '], 5, 'en');
check(plan.pieces[0].length === 0 && plan.next === 5, 'whitespace group consumes no index', plan);

// Continuation across groups: a second block keeps counting upward.
const first = planGroup(['Alpha. Beta.'], 0, 'en');
const second = planGroup(['Gamma.'], first.next, 'en');
check(second.pieces[0][0].sentence === first.next, 'second block continues numbering',
      { first: first.next, second: second.pieces[0][0].sentence });

console.log('\n== realistic paragraph ==');
const para = ['The morning was cold. ', 'Elizabeth', ' walked to the window, opened it, and looked out. ',
              '"How strange," she said. ', 'It was not yet six o\'clock.'];
plan = planGroup(para, 0, 'en');
console.log('  sentences: ' + plan.next);
flat(plan).forEach((list, i) => list.forEach(p => console.log('    node ' + i + ' -> s' + p[0] + ': ' + JSON.stringify(p.text ?? p[1]))));
check(plan.next === 4, 'four sentences in the paragraph', plan.next);

console.log(failures === 0 ? '\nALL CHECKS PASSED' : '\n' + failures + ' CHECK(S) FAILED');
process.exit(failures === 0 ? 0 : 1);
