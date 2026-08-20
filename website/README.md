# boringterminal.com

The landing page and user documentation. Design record: RFC 0021.

One build script, one dependency (`marked`), static output. Requires Node.

```sh
npm install
npm run build    # writes dist/
npm run serve    # build + local preview
```

- `content/index.html` — landing page body
- `content/docs/*.md` — docs pages (`title`/`description` frontmatter);
  sidebar order lives in `NAV` in `build.mjs`
- `static/` — stylesheet, progressive-enhancement script
- The app icon and demo capture are pulled from `../assets/` at build time

Every docs page is also emitted as raw Markdown at `/docs/<slug>.md`
(the "copy as markdown" source), and the build writes `llms.txt` and
`llms-full.txt` at the root.

Rule from RFC 0021: pages document only behavior observable in the shipped
app — never unshipped RFC intent.

Deploy: `.github/workflows/website.yml` builds `dist/` and publishes it to
GitHub Pages (custom domain `boringterminal.com`, CNAME emitted by the build)
on pushes to `main` that touch the site, and on every published release so
the baked download URL and version stay current.
