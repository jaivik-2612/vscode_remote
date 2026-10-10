// SPDX-License-Identifier: GPL-3.0-or-later
// Render guide.html to a PDF with Chromium (Playwright).
// usage: node render.cjs guide.html out.pdf
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const [src, out] = process.argv.slice(2);
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
  const page = await browser.newPage();
  await page.goto('file://' + path.resolve(src), { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.pdf({
    path: out, format: 'A4', printBackground: true,
    margin: { top: '18mm', bottom: '18mm', left: '17mm', right: '17mm' },
    displayHeaderFooter: true,
    headerTemplate: '<span></span>',
    footerTemplate: '<div style="width:100%;font:8px Liberation Sans, sans-serif;color:#6b6f7a;padding:0 17mm;display:flex;justify-content:space-between"><span>Installing Antumbra on the OnePlus 7T Pro</span><span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>',
  });
  await browser.close();
})();
