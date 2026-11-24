const skipped = new Set(['script', 'style', 'noscript', 'template', 'iframe', 'object', 'embed',
  'svg', 'form', 'input', 'textarea', 'select', 'button', 'audio', 'video', 'canvas']);
const allowed = new Set(['p', 'h2', 'h3', 'h4', 'h5', 'h6', 'br', 'hr', 'blockquote',
  'pre', 'code', 'em', 'strong', 'b', 'i', 's', 'sup', 'sub', 'ul', 'ol', 'li',
  'dl', 'dt', 'dd', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'figure', 'figcaption']);
if (!document.body || document.contentType !== 'text/html') return '"noArticle"';
let nodes = 0, units = 0, depth = 0;
const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_ALL);
for (let node = walker.currentNode; node;) {
  if (++nodes > 18000 || depth > 256) return '"tooLarge"';
  if (node instanceof CharacterData) units += node.length;
  else if (node instanceof Element) for (const attr of node.attributes) units += attr.value.length;
  if (units > 1000000) return '"tooLarge"';
  node = walker.firstChild();
  if (node) { depth++; continue; }
  while (!(node = walker.nextSibling()) && depth > 0) {
    walker.parentNode();
    depth--;
  }
}
const copy = document.implementation.createHTMLDocument();
if (document.head) copy.head.replaceWith(copy.importNode(document.head, true));
copy.body.replaceWith(copy.importNode(document.body, true));
const article = new Readability(copy, { maxElemsToParse: 18000, serializer: node => node }).parse();
if (!article || article.textContent.trim().length < 160) return '"noArticle"';
let remaining = 160 * 1024;
let truncated = false;
const encoder = new TextEncoder();
function copyText(node, out, level = 0) {
  if (level > 48) { truncated = true; return; }
  for (const child of node.childNodes) {
    if (remaining <= 0) { truncated = true; return; }
    if (child.nodeType === Node.TEXT_NODE) {
      const full = child.data;
      const text = full.slice(0, 12000).toWellFormed();
      const cost = encoder.encode(JSON.stringify(text)).length + 1;
      if (cost > remaining) { remaining = 0; truncated = true; return; }
      if (text.length !== full.length) truncated = true;
      remaining -= cost;
      out.push(text);
    } else if (child.nodeType === Node.ELEMENT_NODE) {
      const tag = child.localName;
      if (skipped.has(tag) || child.hasAttribute('hidden') || child.getAttribute('aria-hidden') === 'true') continue;
      if (allowed.has(tag)) {
        const children = [];
        remaining -= 24;
        copyText(child, children, level + 1);
        out.push([tag, children]);
      } else {
        copyText(child, out, level + 1);
      }
    }
  }
}
const content = [];
copyText(article.content, content);
const display = (value, length) => (value || '').trim().slice(0, length).toWellFormed();
return JSON.stringify({
  title: display(article.title, 256),
  byline: display(article.byline, 160),
  direction: article.dir === 'rtl' ? 'rtl' : 'auto',
  truncated,
  content,
});
