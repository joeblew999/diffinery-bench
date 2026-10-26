# diffinery-bench

A repeatable side-by-side test of [Diffinery](https://github.com/codician-team/diffinery) against GitHub. The same repo content lives on both sides:

- **GitHub:** this repo
- **Diffinery:** a twin repo on a Diffinery instance (by default `gedw99/claude-trial` on `diffinery.ubuntusoftware.net`)

It checks three things.

1. **CI:** `.github/workflows/bench.yml` runs a Rust release build, a Node matrix, a Postgres service container, cache and artifacts, and Docker. Open a PR with it on both sides, then compare job times with `gh pr checks <n>`, which works against GitHub and Diffinery alike.
2. **API compatibility:** `scripts/apidiff.mjs` asks both sides the same REST questions and lists where Diffinery's answers differ from GitHub's in the fields GitHub clients rely on.
3. **`gh` compatibility:** see the latest results doc for which `gh` commands work against Diffinery.

## Run it

Tools are pinned in `mise.toml`; `mise install`, then `mise tasks` lists the tasks.

The API comparison needs a read-only Diffinery token:

```sh
diffinery login --url https://diffinery.ubuntusoftware.net --scope read
DIFFINERY_TOKEN=$(jq -r .token ~/.config/diffinery/config.json) mise run apidiff
```

Point it at other repos with `GH_REPO`, `GH_PR`, `DIFFINERY_URL`, `DIFFINERY_REPO` and `DIFFINERY_PR`. Raw answers go to `results/latest/` (not committed: they can contain email addresses).

## Results

One dated doc per run in `docs/`, newest last. Latest: [docs/2026-10-26-01-first-comparison.md](docs/2026-10-26-01-first-comparison.md).
