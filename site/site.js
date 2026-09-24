// Fills in the release from /version.json and adds copy buttons to code blocks.
// Every download link already points at /downloads/latest.zip, so the page works without this file.
fetch('/version.json', { cache: 'no-store' })
  .then((r) => (r.ok ? r.json() : null))
  .then((v) => {
    if (!v) return;
    const mb = (v.size / 1e6).toFixed(1) + ' MB';
    const put = (sel, text) => document.querySelectorAll(sel).forEach((el) => { el.textContent = text; el.hidden = false; });
    document.querySelectorAll('a[href="/downloads/latest.zip"]').forEach((a) => a.setAttribute('download', v.file));
    put('[data-v="version"]', v.version);
    put('[data-v="file"]', v.file);
    put('[data-v="size"]', mb);
    put('[data-v="sha256"]', v.sha256);
    put('[data-v="published"]', new Date(v.published).toLocaleDateString(undefined, { dateStyle: 'long' }));
    document.querySelectorAll('[data-v-show]').forEach((el) => { el.hidden = false; });
  })
  .catch(() => {});

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

// Collapsed FAQ questions and changelog releases open when a link points at them.
function openTarget() {
  const el = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
  if (el && el.tagName === 'DETAILS') { el.open = true; el.scrollIntoView(); }
}
addEventListener('hashchange', openTarget);
openTarget();
