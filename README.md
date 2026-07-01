# bukuwarung-second-brain

A public Claude Code plugin **marketplace** hosting [`second-brain-capture`](./second-brain-capture) — a companion plugin that turns each Claude Code working session into one curated, PII-redacted note in a Cortex knowledge base.

This repo is public **only so the plugin installs with zero GitHub auth** (a private marketplace can't be fetched by machines that aren't authenticated to it). It contains no credentials — the OAuth secret is supplied at runtime via settings `env`, never committed here.

## Install

Add the marketplace and enable the plugin:

```
/plugin marketplace add bukuwarung/second-brain-capture
/plugin install second-brain-capture@bukuwarung-second-brain
```

For fleet rollout this is done non-interactively via managed settings (`extraKnownMarketplaces` + `enabledPlugins`), with the OAuth credentials injected through the `env` block. See the [plugin README](./second-brain-capture/README.md).

## What's here

- `second-brain-capture/` — the plugin (hooks, scripts, `setup` command).
- `.claude-plugin/marketplace.json` — the marketplace manifest.

Source of truth is BukuWarung's internal Cortex repo; this repo is a distribution mirror.
