# Stem Exporter marketing site

A small static marketing site for Stem Exporter, styled with
[Tailwind CSS v4](https://tailwindcss.com). It's deployed to GitHub Pages by
[`.github/workflows/deploy-pages.yml`](../.github/workflows/deploy-pages.yml)
on every push to `main` that touches this folder.

## Structure

- `public/index.html` — the page markup (also the build output directory).
- `src/input.css` — Tailwind entry point.
- `public/app.css` — generated Tailwind output (not committed, built by CI).

## Local development

```bash
npm install
npm run watch   # rebuilds public/app.css on change
```

Then open `public/index.html` in a browser, or serve the `public/` folder with
any static file server.

To produce the minified stylesheet used in production:

```bash
npm run build
```
