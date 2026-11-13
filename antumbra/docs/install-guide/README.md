# The install guide

`guide.html` is the source of `../antumbra-install-guide.pdf`, the
step-by-step install guide for Windows, macOS and Linux users. It follows
`../flashing.md`; change both together. To render it (Playwright and
Chromium; `CHROMIUM` may name the browser binary):

```sh
node render.cjs guide.html ../antumbra-install-guide.pdf
```

The fonts are subsets of the image's own: Roboto (`fonts-roboto-unhinted`,
Apache-2.0) and Noto Sans Mono (`fonts-noto-mono`, SIL Open Font License
1.1), covering Latin, punctuation and arrows.
