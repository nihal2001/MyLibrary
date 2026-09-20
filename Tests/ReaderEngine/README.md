# Reader engine tests

The reader's pagination and sentence-focus logic is JavaScript living in a Swift
string literal (`MyLibrary/Reader/ReaderEngine.swift`), which no XCTest target
can reach. These tests read that Swift file, extract the script, and run it in
[jsdom](https://github.com/jsdom/jsdom).

```sh
cd Tests/ReaderEngine
npm install
npm test
```

Optional — nothing in the Xcode build depends on them.

- `segmentation.test.js` covers sentence splitting in isolation: abbreviations
  ("Mr. Bennet" stays whole), quoted dialogue, initials, ellipses, CJK
  terminators, and the offset mapping that lets one sentence span several text
  nodes. `core.js` is that logic as a standalone module, kept in step with the
  copy inside `ReaderEngine.swift`.
- `engine.test.js` boots the real extracted engine in a DOM and checks wrapping,
  text integrity, stepping, edge messages at chapter boundaries, runtime
  toggling, and the handling of scripts, lists, and links.

Note that jsdom does no layout, so `getClientRects()` returns zeros and the
page-turn arithmetic in `revealSpan` is *not* covered here — that part needs a
real device or simulator.
