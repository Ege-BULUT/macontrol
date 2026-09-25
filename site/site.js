// Adds copy buttons to code blocks and collapses FAQ questions and changelog releases.
// The release (version, size, SHA-256) is written into the HTML at deploy time, so the pages work without this file.
document.querySelectorAll('pre > code').forEach((code) => {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'copy';
  b.textContent = 'Copy';
  b.addEventListener('click', () => {
    navigator.clipboard.writeText(code.innerText.trim()).then(
      () => { b.textContent = 'Copied'; setTimeout(() => { b.textContent = 'Copy'; }, 1600); },
      () => { b.textContent = 'Select and copy'; }
    );
  });
  const wrap = document.createElement('div');
  wrap.className = 'code';
  code.parentElement.before(wrap);
  wrap.append(code.parentElement, b);
});

// Accordion: each .acc keeps its <h2>, and a button inside the heading shows or hides the .acc-body after it
// (the WAI-ARIA accordion pattern). Without JavaScript every answer stays open. data-open starts one open,
// a link to a section opens it, and find in page opens the one it matches (hidden="until-found").
document.querySelectorAll('.acc').forEach((acc) => {
  const h = acc.querySelector('h2');
  const body = acc.querySelector('.acc-body');
  const b = document.createElement('button');
  b.type = 'button';
  b.append(...h.childNodes);
  h.append(b);
  body.id = acc.id + '-body';
  b.setAttribute('aria-controls', body.id);
  acc.setOpen = (open) => {
    b.setAttribute('aria-expanded', open);
    body.hidden = open ? false : 'until-found';
  };
  b.addEventListener('click', () => acc.setOpen(body.hidden !== false));
  body.addEventListener('beforematch', () => acc.setOpen(true));
  acc.setOpen(acc.hasAttribute('data-open'));
});

function openTarget() {
  const el = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
  if (el && el.setOpen) { el.setOpen(true); el.scrollIntoView(); }
}
addEventListener('hashchange', openTarget);
openTarget();
