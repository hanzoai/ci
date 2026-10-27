// sitemap.xml for a bundle that ships none: every public page at its canonical
// URL (https, no trailing slash, no .html).

function xml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function sitemap(urls: string[]): string {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...urls.map((u) => `<url><loc>${xml(u)}</loc></url>`),
    '</urlset>',
    '',
  ].join('\n');
}
