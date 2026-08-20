// Static site builder for boringterminal.com. One script, no framework.
//
//   content/index.html   landing page body fragment
//   content/docs/*.md    documentation pages (frontmatter: title, description)
//   static/*             copied verbatim into dist/
//
// Outputs dist/: the landing page, /docs/<slug>/ pages, the raw markdown at
// /docs/<slug>.md (served for "copy page as Markdown"), llms.txt, llms-full.txt.

import { marked } from 'marked';
import { mkdir, readFile, writeFile, cp, rm, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, 'dist');

const zon = await readFile(path.join(root, '../build.zig.zon'), 'utf8');
const version = zon.match(/\.version = "([^"]+)"/)?.[1];
if (!version) throw new Error('could not read .version from build.zig.zon');

const SITE = {
  title: 'Boring Terminal',
  tagline: 'A calm, fast macOS terminal built around long-running sessions.',
  url: 'https://boringterminal.com',
  domain: 'boringterminal.com',
  repo: 'https://github.com/boringterminal/boringterminal',
  download: 'https://github.com/boringterminal/boringterminal/releases/latest',
  version,
  dmg: `https://github.com/boringterminal/boringterminal/releases/download/v${version}/Boring-Terminal-v${version}-macos-universal.dmg`,
};

// Sidebar order. Slugs match content/docs/<slug>.md.
const NAV = [
  { group: 'Start here', pages: ['introduction', 'install'] },
  { group: 'Using it', pages: ['sessions', 'agents', 'keyboard-shortcuts', 'configuration'] },
  { group: 'Reference', pages: ['compatibility', 'philosophy'] },
];

// ---------------------------------------------------------------- markdown

const slugify = (text) =>
  text.toLowerCase().replace(/<[^>]+>/g, '').replace(/[^a-z0-9\s-]/g, '')
    .trim().replace(/\s+/g, '-');

marked.use({
  renderer: {
    heading({ tokens, depth }) {
      const text = this.parser.parseInline(tokens);
      const id = slugify(text);
      return `<h${depth} id="${id}"><a class="anchor" href="#${id}" aria-hidden="true">#</a>${text}</h${depth}>\n`;
    },
  },
});

function parseFrontmatter(source) {
  const match = source.match(/^---\n([\s\S]*?)\n---\n/);
  if (!match) return { meta: {}, body: source };
  const meta = {};
  for (const line of match[1].split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return { meta, body: source.slice(match[0].length) };
}

// ---------------------------------------------------------------- layout

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');

function shell({ title, description, body, bodyClass = '' }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${SITE.url}/icon.png">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body class="${bodyClass}">
${body}
<script src="/site.js" defer></script>
</body>
</html>
`;
}

function header(active) {
  const link = (href, label, key) =>
    `<a href="${href}"${active === key ? ' aria-current="page"' : ''}>${label}</a>`;
  return `<header class="top">
  <div class="col row">
    <a class="brand" href="/">Boring Terminal</a>
    <nav>
      ${link('/docs/introduction/', 'docs', 'docs')}
      <a href="${SITE.repo}">github</a>
      <a class="dl" href="${SITE.download}">download</a>
    </nav>
  </div>
</header>`;
}

const footer = `<footer class="bottom">
  <div class="col row">
    <span>© ${new Date().getFullYear()} Boring Terminal · MIT</span>
    <span><a href="/llms.txt">llms.txt</a> · <a href="${SITE.repo}">source</a></span>
  </div>
</footer>`;

function sidebar(pages, activeSlug) {
  const groups = NAV.map(({ group, pages: slugs }) => {
    const items = slugs.map((slug) => {
      const page = pages.get(slug);
      const current = slug === activeSlug ? ' aria-current="page"' : '';
      return `<li><a href="/docs/${slug}/"${current}>${esc(page.meta.title)}</a></li>`;
    }).join('\n      ');
    return `    <section>
      <h2>${esc(group)}</h2>
      <ul>
      ${items}
      </ul>
    </section>`;
  }).join('\n');
  return `<aside class="sidebar" id="sidebar">
  <nav aria-label="Documentation">
${groups}
  </nav>
</aside>`;
}

function docsPage(pages, order, slug) {
  const page = pages.get(slug);
  const i = order.indexOf(slug);
  const prev = i > 0 ? pages.get(order[i - 1]) : null;
  const next = i < order.length - 1 ? pages.get(order[i + 1]) : null;
  const pager = `<nav class="pager">
  ${prev ? `<a class="prev" href="/docs/${prev.slug}/"><small>previous</small><span>${esc(prev.meta.title)}</span></a>` : '<span></span>'}
  ${next ? `<a class="next" href="/docs/${next.slug}/"><small>next</small><span>${esc(next.meta.title)}</span></a>` : '<span></span>'}
</nav>`;

  const body = `${header('docs')}
<div class="docs col">
<button class="sidebar-toggle" aria-controls="sidebar" aria-expanded="false">menu</button>
${sidebar(pages, slug)}
<main>
<div class="page-tools">
  <button class="copy-md" data-md="/docs/${slug}.md">copy as markdown</button>
  <a href="/docs/${slug}.md">view raw</a>
</div>
<article>
<h1>${esc(page.meta.title)}</h1>
${page.html}
</article>
${pager}
${footer}
</main>
</div>`;

  return shell({
    title: `${page.meta.title} · ${SITE.title}`,
    description: page.meta.description || SITE.tagline,
    body,
    bodyClass: 'docs-body',
  });
}

// ---------------------------------------------------------------- build

async function build() {
  await rm(dist, { recursive: true, force: true });
  await mkdir(path.join(dist, 'docs'), { recursive: true });

  // Docs pages.
  const order = NAV.flatMap((g) => g.pages);
  const pages = new Map();
  for (const slug of order) {
    const source = await readFile(path.join(root, 'content/docs', `${slug}.md`), 'utf8');
    const { meta, body } = parseFrontmatter(source);
    if (!meta.title) throw new Error(`${slug}.md: missing title in frontmatter`);
    pages.set(slug, { slug, meta, body, html: marked.parse(body) });
  }

  for (const slug of order) {
    const page = pages.get(slug);
    await mkdir(path.join(dist, 'docs', slug), { recursive: true });
    await writeFile(path.join(dist, 'docs', slug, 'index.html'), docsPage(pages, order, slug));
    await writeFile(path.join(dist, 'docs', `${slug}.md`), `# ${page.meta.title}\n\n${page.body}`);
  }

  // The hero mark is the shared icon inlined with SMIL animation. The dashes
  // never stop being dashes: K rarely glances aside (both slide together),
  // later raises a skeptical left brow (lift and tilt), and perks up when
  // hovered (both dashes rise). All values share one M/l structure so SMIL
  // interpolates them.
  const sourceFace = 'M240 502h160M624 502h160';
  const rest = 'M240 502l160 0M624 502l160 0';
  const glance = 'M288 502l160 0M672 502l160 0';
  const brow = 'M240 484l160 -18M624 502l160 0';
  const perk = 'M240 480l160 0M624 480l160 0';
  const idle = `<animate attributeName="d" dur="14s" repeatCount="indefinite" calcMode="spline"
    keyTimes="0;0.40;0.415;0.47;0.485;0.76;0.775;0.84;0.86;1"
    keySplines="0 0 1 1;0.3 0 0.2 1;0 0 1 1;0.3 0 0.2 1;0 0 1 1;0.3 0 0.2 1;0 0 1 1;0.3 0 0.2 1;0 0 1 1"
    values="${rest};${rest};${glance};${glance};${rest};${rest};${brow};${brow};${rest};${rest}"/>`;
  const peek = `<animate attributeName="d" begin="kmark.mouseenter" dur="1.2s" calcMode="spline"
    keyTimes="0;0.15;0.8;1" keySplines="0.2 0 0.1 1;0 0 1 1;0.4 0 0.2 1"
    values="${rest};${perk};${perk};${rest}"/>`;
  const iconSource = await readFile(path.join(root, '../assets/AppIcon.svg'), 'utf8');
  const heroMark = iconSource
    .replace('<svg ', '<svg id="kmark" class="mark" width="56" height="56" role="img" aria-label="K, the Boring Terminal icon" ')
    .replace(new RegExp(`(<path d="${sourceFace}"[^/]*)/>`, 'g'), `$1>${idle}${peek}</path>`);
  if (!heroMark.includes('<animate')) throw new Error('hero mark animation injection failed');

  // Landing page.
  const landing = (await readFile(path.join(root, 'content/index.html'), 'utf8'))
    .replaceAll('{{VERSION}}', SITE.version)
    .replaceAll('{{DMG_URL}}', SITE.dmg)
    .replaceAll('{{RELEASES_URL}}', SITE.download)
    .replace('{{HERO_MARK}}', heroMark);
  await writeFile(path.join(dist, 'index.html'), shell({
    title: `${SITE.title} · ${SITE.tagline}`,
    description: SITE.tagline,
    body: `${header('home')}\n${landing}\n${footer}`,
    bodyClass: 'landing',
  }));

  // GitHub Pages: custom domain and the not-found page.
  await writeFile(path.join(dist, 'CNAME'), `${SITE.domain}\n`);
  await writeFile(path.join(dist, '404.html'), shell({
    title: `Not found · ${SITE.title}`,
    description: SITE.tagline,
    body: `${header('home')}\n<main class="col landing-col"><section class="hero">
<h1>404</h1>
<p class="tagline">There is no such page. That is the boring, honest answer.</p>
<p class="actions"><a class="button ghost" href="/">Home</a>
<a class="button ghost" href="/docs/introduction/">Docs</a></p>
</section></main>\n${footer}`,
    bodyClass: 'landing',
  }));

  // llms.txt + llms-full.txt.
  const lines = [`# ${SITE.title}`, '', `> ${SITE.tagline}`, '', '## Docs', ''];
  for (const slug of order) {
    const { meta } = pages.get(slug);
    lines.push(`- [${meta.title}](${SITE.url}/docs/${slug}.md): ${meta.description || ''}`);
  }
  await writeFile(path.join(dist, 'llms.txt'), lines.join('\n') + '\n');
  const full = order.map((slug) => {
    const page = pages.get(slug);
    return `# ${page.meta.title}\n\n${page.body}`;
  }).join('\n\n---\n\n');
  await writeFile(path.join(dist, 'llms-full.txt'), full + '\n');

  // Static files and shared assets.
  for (const entry of await readdir(path.join(root, 'static'))) {
    await cp(path.join(root, 'static', entry), path.join(dist, entry), { recursive: true });
  }
  await cp(path.join(root, '../assets/AppIcon.svg'), path.join(dist, 'icon.svg'));
  // The favicon is the same icon cropped to the chrome squircle (x/y 76,
  // 872 square): the macOS icon grid's transparent margin reads undersized
  // at browser-tab size.
  const iconSvg = await readFile(path.join(root, '../assets/AppIcon.svg'), 'utf8');
  await writeFile(
    path.join(dist, 'favicon.svg'),
    iconSvg.replace('viewBox="0 0 1024 1024"', 'viewBox="76 76 872 872"'),
  );
  await cp(path.join(root, '../assets/AppIcon.iconset/icon_512x512@2x.png'), path.join(dist, 'icon.png'));
  await cp(
    path.join(root, '../assets/readme/session-management.gif'),
    path.join(dist, 'assets/session-management.gif'),
  );

  console.log(`built ${order.length + 1} pages -> ${path.relative(process.cwd(), dist)}`);
}

await build();
