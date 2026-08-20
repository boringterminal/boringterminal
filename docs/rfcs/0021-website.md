# RFC 0021: Website and documentation site

Status: accepted

## Summary

`boringterminal.com` (named canonical in RFC 0000) gets a real site: a minimal
landing page and user-facing documentation. It lives in `website/` in this
repository and is a fully static build.

## Goals

- A landing page that states what the product is in one screen: icon, one
  sentence, download, one demo capture, a terse feature list. Inspirations:
  fx.sh (density, restraint), ghostty.org (docs structure).
- Documentation for **users**, not contributors: install, sessions, attention
  routing for agent authors, shortcuts, configuration, compatibility,
  philosophy. RFCs and references stay in `docs/` as the contributor surface;
  the website must never document designed-but-unshipped behavior.
- Agent-legible docs, matching principle 2 of RFC 0000: every page is
  retrievable as raw Markdown (`/docs/<slug>.md`, a "copy as markdown" button
  on each page), plus `llms.txt` and `llms-full.txt` at the site root.

## Design

- **Stack: one Node build script** (`website/build.mjs`) with a single
  dependency (`marked`). No framework, no SSG, no client-side rendering. The
  output is plain HTML/CSS plus a small progressive-enhancement script (copy
  buttons, mobile nav); the site works with JavaScript disabled.
- **Look:** grayscale, compact, one narrow centered column (fx.sh density —
  never full viewport width on large screens), light and dark via
  `prefers-color-scheme`. Crisp system sans for everything except code/kbd,
  which stay mono — a terminal app is not obliged to typeset its website in
  monospace. No webfonts. The wordmark in chrome is text-only; the icon is
  never placed small beside it. Same taste as the app icon: minimal, boring,
  HD.
- **Positioning:** the site frames the product as built in the agent era, for
  humans and agents alike. RFC 0000's one-line test may be quoted as the
  internal design test, but copy must not present the product as agents-only.
- **Content:** Markdown files in `website/content/docs/` with `title` /
  `description` frontmatter; sidebar order is a literal list in the build
  script. The landing page is a hand-written HTML fragment.
- **Assets are shared, not copied:** the build pulls the app icon and the
  original-quality demo capture from `assets/` at build time.

### K hero motion amendment (2026-08-20)

The landing-page hero inlines the shared K SVG so its two dashes can move
without introducing a second logo asset. Motion remains infrequent and inside
the mark: a glance, a skeptical brow, and a short hover response. The chrome,
screen, and identity never transform, and the dashes never become another
symbol. The static app icon and documentation chrome remain motionless.

The build fails if it cannot find the canonical two-dash geometry instead of
silently emitting a different mark. The progressive-enhancement script removes
the SVG animation for `prefers-reduced-motion`; removing JavaScript leaves the
complete landing page usable and changes only that cosmetic preference hook.

## Rejected alternatives

- **Astro/Starlight, VitePress, or similar.** Best-in-class docs UX out of the
  box, but drags a framework dependency tree into a Zig repository and needs
  heavy theme surgery to stop looking like every other docs site. The feature
  set we actually need (sidebar, prev/next, copy-md, llms.txt) is a page of
  code.
- **Separate website repository.** Splits versioning from the product for no
  benefit at this size; docs must move in the same commit as behavior.
- **Documenting from the RFCs.** RFCs record intent, including unshipped
  intent. Website pages are written only from behavior observable in the app.

## Deployment

The build emits `website/dist/`, deployed to GitHub Pages at
`boringterminal.com` by `.github/workflows/website.yml`: push to `main`
touching `website/`, `assets/`, or `build.zig.zon` rebuilds and deploys, and
a published release does too (the landing page bakes the release's exact DMG
URL and version from `build.zig.zon`, so the site re-deploys when a release
ships). The build emits the `CNAME` file and a 404 page.

The download button opens a native `<dialog>` that starts the DMG download
through a hidden iframe (a failed asset URL cannot navigate away from the
page) and shows the three Gatekeeper first-launch paths. Without JavaScript
it is a plain link to GitHub releases.
