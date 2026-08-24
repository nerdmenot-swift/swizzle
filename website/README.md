# The Swizzle website

`swizzle.nerdmenot.in`. Astro + Starlight, deployed to Cloudflare Pages.

```
bun install
bun run dev        # extracts, then serves
bun run build
bun run deploy
```

## The one rule

**Nothing on this site is written by hand into a code block.**

`scripts/extract.ts` builds a throwaway Swift package against the real library, renders
each demo query through the real `QueryBuilder` once per dialect, and writes the results
to `src/data/demos.json`. The migration and the generated-code samples are read verbatim
out of `examples/`.

That is not neatness for its own sake. Swizzle's central claim is that one expression
renders correctly *per dialect* — and a hand-typed example proves only that somebody once
believed it. This way, if the renderer changes, the site changes with it.

Which is why the landing page can show `$1` for Postgres and `` `users` `` for MySQL side
by side and mean it.

## Without a Swift toolchain

`bun run dev` still works. If `swift` is missing, the extract step says so, keeps whatever
it wrote last time, and exits zero — so a fresh clone serves, and a stale demo shows up in
the diff rather than being silently regenerated as a mock.

## Still to do

- **The icon is a placeholder.** `public/icon.svg` is a stand-in glass, and says so in a
  comment. Replace it with the real mark once exported, along with `src/assets/icon.svg`.
- **No wordmark yet**, so the header uses icon + live text. Swap for a lockup when there
  is one — decoy's header is the reference.
- Six docs pages are stubs. The behaviour is implemented and tested; the prose is not
  written.
