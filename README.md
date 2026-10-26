# diffinery-bench

A repeatable side-by-side test of [Diffinery](https://github.com/codician-team/diffinery) against GitHub, using **identical twin repos**:

- **GitHub:** this repo
- **Diffinery:** its twin, `gedw99/diffinery-bench` on `diffinery.ubuntusoftware.net`, made with Diffinery's importer and kept identical by `twin:sync` (GitHub wins)

It checks three things.

1. **CI:** `.github/workflows/bench.yml` (Rust release build, Node matrix, Postgres service container, cache and artifacts, Docker) runs on GitHub Actions and on Diffinery's CI from the same file. Start it on both at once (`gh workflow run bench.yml` on GitHub; dispatch it on Diffinery) and compare the job times.
2. **API compatibility:** `scripts/apidiff.mjs` asks both sides the same REST questions (28 endpoints) and lists where Diffinery's answers differ in the fields GitHub clients rely on.
3. **`gh` compatibility:** `scripts/ghcheck.sh` runs the same `gh` commands, reads and writes, against either side. A command counts as working only if its output shows the expected item.

## The twins test themselves

`.github/workflows/check.yml` runs on every push to `main`, on GitHub Actions **and** on Diffinery: it installs mise and runs `mise run check:self`, which checks the platform it runs on against itself with the job's own token, and uploads the results. So one merge gives two result sets:

1. merge on GitHub: GitHub runs `check`
2. `mise run twin:sync`: the twin gets the same commit, so Diffinery runs `check`
3. `mise run twin:collect`: download both and compare them side by side

## Run it

Tools are pinned in `mise.toml`; `mise install`, then `mise tasks` lists the tasks. The Diffinery side needs a token from a Diffinery login (choose **write** on the authorize page; **admin** only if a branch is protected):

```sh
diffinery login --url https://diffinery.ubuntusoftware.net
export DIFFINERY_TOKEN=$(jq -r .token ~/.config/diffinery/config.json)
diffinery auth setup-gh      # lets gh talk to the Diffinery host
mise run check               # sync the twin, compare the APIs, run the gh checks
```

Point it at other repos with `GH_REPO`, `GH_PR`, `DIFFINERY_URL`, `DIFFINERY_HOST`, `DIFFINERY_REPO` and `DIFFINERY_PR`. Raw API answers go to `results/latest/` (not committed: they can contain email addresses).

The GitHub side of the `gh` check (`mise run ghcheck:github`) needs a normal `gh` login, such as on a Mac: Claude cloud sessions block GitHub's GraphQL API, which most `gh` commands use.

## Results

One dated doc per run in `docs/`, newest last. Latest: [docs/2026-10-26-03-twin-ci.md](docs/2026-10-26-03-twin-ci.md).
