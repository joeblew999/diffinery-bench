# 2026-10-26-01-first-comparison.md

First run of this kit: the same CI workflow and the same API questions against GitHub and a self-hosted Diffinery (0.1.0, deployed 2026-10-26 at diffinery.ubuntusoftware.net).

| | GitHub | Diffinery |
|---|---|---|
| Repo | `joeblew999/diffinery-bench` (public) | `gedw99/claude-trial` (private) |
| Bench PR | #1 | #3 |
| Runner | `ubuntu-latest`, 4 vCPU (public repo) | default "large", 4 vCPU / 12 GB, Cloudflare Containers |

## 1. CI benchmark (`.github/workflows/bench.yml`)

All 12 jobs passed on both: marketplace actions, a matrix, a Postgres service container, cache, artifacts and Docker work unchanged on Diffinery.

| Job | GitHub | Diffinery |
|---|---|---|
| Rust release build (ripgrep 14.1.1) | **39 s** | 46 s (13 s of it installing Rust, which GitHub's image has preinstalled) |
| Postgres service | **21 s** | 32 s (about 20 s starting the database) |
| Node 20 | 10 s | 11 s |
| Node 22 | 10 s | **8 s** |
| Docker build and run | 9 s | **5 s** |
| Cache and artifacts | 6 s | **5 s** |
| Whole run | **about 41 s** | 53 s |
| Cost | $0 (public repo) | about $0.006 (inside the Workers Paid allowance) |

Notes:
- GitHub gives **public** repos 4-vCPU runners free; private repos get 2 vCPU. The fairer test of Diffinery's bigger runners is a private repo (not yet run).
- Diffinery jobs started 5–7 s after the PR opened and ran in several Cloudflare locations (Mumbai, Los Angeles, Ashburn).

## 2. API compatibility (`scripts/apidiff.mjs`)

Same REST questions to both, compared on the fields GitHub clients rely on.

**Matches:** pull requests (list and detail), issues over REST (list and detail), commit status.

**Real incompatibilities:**

1. **GraphQL leaves out issues.** `repository { issues { … } pullRequests { … } }` returns only `pullRequests`, with no error. This is why `gh issue list` shows nothing and `gh issue view 2` says "issue was not found but GraphQL reported no error".
2. **Numeric IDs are strings.** `workflow_runs[].id`, `workflow_runs[].workflow_id`, `jobs[].id`, `jobs[].run_id`, `check_runs[].check_suite.id` and `check_runs[].app.id` are hex strings on Diffinery, numbers on GitHub. `gh run list` fails: `json: cannot unmarshal string into Go struct field Run.workflow_runs.ID of type int64`.
3. **Workflow runs are thinner.** Missing `repository`, `head_repository` and `head_commit`; `pull_requests[]` items lack `id`, `head` and `base`. Jobs lack `created_at` and `labels`. Check runs' `pull_requests[]` items lack `url`, `id`, `number`, `head` and `base`.

**Noise (ignored):** GitHub-only `security_and_analysis` settings, and `performed_via_github_app` (the GitHub test issue was created through a GitHub App).

## 3. `gh` against Diffinery (gh 2.89, after `diffinery auth setup-gh`)

| Command | Result |
|---|---|
| `gh auth status`, `gh repo view` | work |
| `gh pr list`, `gh pr view 3`, `gh pr checks 3`, `gh pr diff 3` | work |
| `gh issue list`, `gh issue view 2` | broken (finding 1) |
| `gh run list` | broken (finding 2) |

## 4. Driving each side from Claude

- **Diffinery connector:** created commits including workflow files, opened PRs, read runs and logs. About 1 in 4 to 1 in 8 calls failed with a 502 from Anthropic's connector relay; the failed requests never reached the server (reported as anthropics/claude-ai-mcp#1185, cross-linked in codician-team/diffinery#3).
- **GitHub connector:** could not create a repo or write workflow files (no permission), so those steps were done by hand.
