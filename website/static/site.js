// Progressive enhancement only: copy buttons and the mobile sidebar toggle.
// The site is fully usable with this file blocked.

function flash(button, label) {
  const original = button.textContent;
  button.textContent = label;
  button.classList.add('done');
  setTimeout(() => {
    button.textContent = original;
    button.classList.remove('done');
  }, 1600);
}

// "Copy as markdown" — fetches the raw .md emitted next to each page.
document.querySelectorAll('.copy-md').forEach((button) => {
  button.addEventListener('click', async () => {
    try {
      const res = await fetch(button.dataset.md);
      await navigator.clipboard.writeText(await res.text());
      flash(button, 'copied');
    } catch {
      flash(button, 'failed');
    }
  });
});

// Copy button on every code block. The pre is its own horizontal scroll
// container, so the button anchors to a non-scrolling wrapper instead.
document.querySelectorAll('article pre, #download-modal pre').forEach((pre) => {
  const wrapper = document.createElement('div');
  wrapper.className = 'codeblock';
  pre.parentNode.insertBefore(wrapper, pre);
  wrapper.appendChild(pre);
  const button = document.createElement('button');
  button.className = 'copy-code';
  button.textContent = 'copy';
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(pre.querySelector('code')?.innerText ?? pre.innerText);
      flash(button, 'copied');
    } catch {
      flash(button, 'failed');
    }
  });
  wrapper.appendChild(button);
});

// CSS cannot reach SMIL: strip K's blink for reduced-motion users.
if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
  document.querySelectorAll('#kmark animate').forEach((a) => a.remove());
}

// Download modal: open, start the DMG download, show first-launch steps.
// Without JavaScript the button is a plain link to GitHub releases.
const downloadModal = document.getElementById('download-modal');
if (downloadModal) {
  document.querySelectorAll('[data-download]').forEach((link) => {
    link.addEventListener('click', (event) => {
      event.preventDefault();
      downloadModal.showModal();
      // An iframe keeps the page in place: a healthy asset URL answers with
      // an attachment and downloads; a failing one fails silently and the
      // modal's direct links remain the fallback.
      const frame = document.createElement('iframe');
      frame.hidden = true;
      frame.src = downloadModal.dataset.dmg;
      document.body.appendChild(frame);
    });
  });
  downloadModal.querySelector('.modal-close').addEventListener('click', () => downloadModal.close());
  downloadModal.addEventListener('click', (event) => {
    if (event.target === downloadModal) downloadModal.close();
  });
}

// Mobile sidebar.
const toggle = document.querySelector('.sidebar-toggle');
if (toggle) {
  toggle.addEventListener('click', () => {
    const sidebar = document.getElementById('sidebar');
    const open = sidebar.classList.toggle('open');
    toggle.setAttribute('aria-expanded', String(open));
  });
}
