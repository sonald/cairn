# Cairn homepage

Static HTML, CSS and a small vanilla `script.js` (the interactive reader and snapshot demos); no build step or runtime dependencies. The screenshot is stored at `site/assets/reader.png`.

## Preview

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open http://127.0.0.1:8765.

## Publish

In the repository's **Settings → Pages**, select **GitHub Actions** as the source. After this change is merged into `main`, `pages.yml` publishes only `site/`. The expected project URL is https://sonald.github.io/cairn/ (not published by local preview).

Workflow configuration follows [GitHub's Pages documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Demo data

The interactive reader and snapshot timeline use real results from [sonald/knuth-rs](https://github.com/sonald/knuth-rs) at `fac975a`: callers, resolutions and certainty from `codeinsight callers`/`resolve`, Exact targets from `codeinsight exact-def` (rust-analyzer, Safe mode), and the `HookContext` history from `git show <commit>:crates/knuth-agent/src/hooks/types.rs`. Re-run those commands against a clean checkout of that commit when updating the data.
