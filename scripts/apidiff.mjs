// apidiff.mjs: ask GitHub and Diffinery the same REST questions and compare the answers'
// shape. Wherever Diffinery's answer differs from GitHub's, GitHub tools (gh, Octokit, IDEs)
// are likely to break.
//
// Usage (via mise, see mise.toml):
//   node scripts/apidiff.mjs fetch github      # needs nothing for a public repo (GITHUB_TOKEN optional)
//   node scripts/apidiff.mjs fetch diffinery   # needs DIFFINERY_TOKEN (diffinery login, read scope)
//   node scripts/apidiff.mjs compare           # prints the differences
//   node scripts/apidiff.mjs all               # all three
//
// Answers are saved to results/latest/api-<side>.json.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

const env = process.env;
const sides = {
  github: {
    base: "https://api.github.com",
    repo: env.GH_REPO || "joeblew999/diffinery-bench",
    pr: Number(env.GH_PR || 3),
    issue: Number(env.GH_ISSUE || 2),
    token: env.GITHUB_TOKEN || "",
  },
  diffinery: {
    base: `${(env.DIFFINERY_URL || "https://diffinery.ubuntusoftware.net").replace(/\/$/, "")}/api/v3`,
    repo: env.DIFFINERY_REPO || "gedw99/diffinery-bench",
    pr: Number(env.DIFFINERY_PR || 3),
    issue: Number(env.DIFFINERY_ISSUE || 2),
    token: env.DIFFINERY_TOKEN || "",
  },
  // "self": the platform this is running on, inside its own CI (GitHub Actions or Diffinery),
  // using the job's own API URL, repository and token.
  self: {
    base: (env.GITHUB_API_URL || "").replace(/\/$/, ""),
    repo: env.GITHUB_REPOSITORY || "",
    pr: Number(env.CHECK_PR || 3),
    issue: Number(env.CHECK_ISSUE || 2),
    token: env.GITHUB_TOKEN || "",
  },
};
const outDir = new URL("../results/latest/", import.meta.url).pathname;

function get(side, path) {
  const s = sides[side];
  const args = ["-s", "--max-time", "30", "-w", "\n%{http_code}", "-H", "accept: application/vnd.github+json", "-H", "user-agent: diffinery-bench-apidiff"];
  if (s.token) args.push("-H", `authorization: Bearer ${s.token}`);
  args.push(s.base + path);
  for (let i = 0; i < 4; i++) {
    try {
      const raw = execFileSync("curl", args, { encoding: "utf8", maxBuffer: 50e6 });
      const nl = raw.lastIndexOf("\n");
      const status = Number(raw.slice(nl + 1));
      const text = raw.slice(0, nl);
      if (!status) throw new Error("no response");
      try { return { status, body: JSON.parse(text) }; } catch { return { status, body: text.slice(0, 200) }; }
    } catch { execFileSync("sleep", ["2"]); }
  }
  return { status: 0, body: "network error" };
}

function fetchSide(side) {
  const { repo, pr, issue } = sides[side];
  if (side === "diffinery" && !sides.diffinery.token) throw new Error("set DIFFINERY_TOKEN (diffinery login --scope read)");
  if (side === "self" && !(sides.self.base && sides.self.repo)) throw new Error("self needs GITHUB_API_URL and GITHUB_REPOSITORY (set by CI)");
  const out = {};
  const q = (name, path) => { out[name] = get(side, path); };
  q("repo", `/repos/${repo}`);
  q("pulls", `/repos/${repo}/pulls?state=all`);
  q("pull", `/repos/${repo}/pulls/${pr}`);
  q("issues", `/repos/${repo}/issues?state=all`);
  q("issue", `/repos/${repo}/issues/${issue}`);
  q("runs", `/repos/${repo}/actions/runs`);
  const runs = out.runs.body?.workflow_runs || [];
  const run = runs.find((r) => r.name === "bench") || runs[0];
  if (run) q("jobs", `/repos/${repo}/actions/runs/${run.id}/jobs`);
  const sha = out.pull.body?.head?.sha;
  if (sha) {
    q("check_runs", `/repos/${repo}/commits/${sha}/check-runs`);
    q("status", `/repos/${repo}/commits/${sha}/status`);
  }
  if (run) {
    q("run", `/repos/${repo}/actions/runs/${run.id}`);
    q("run_logs_redirect", `/repos/${repo}/actions/runs/${run.id}/logs`);
  }
  q("workflows", `/repos/${repo}/actions/workflows`);
  q("branches", `/repos/${repo}/branches`);
  q("branch_main", `/repos/${repo}/branches/main`);
  q("commits", `/repos/${repo}/commits?sha=main&per_page=5`);
  q("commit_main", `/repos/${repo}/commits/main`);
  q("contents_root", `/repos/${repo}/contents/`);
  q("contents_readme", `/repos/${repo}/contents/README.md`);
  q("readme", `/repos/${repo}/readme`);
  q("compare", `/repos/${repo}/compare/main~1...main`);
  q("labels", `/repos/${repo}/labels`);
  q("releases", `/repos/${repo}/releases`);
  q("tags", `/repos/${repo}/tags`);
  q("issue_comments", `/repos/${repo}/issues/${issue}/comments`);
  q("pull_files", `/repos/${repo}/pulls/${pr}/files`);
  q("pull_commits", `/repos/${repo}/pulls/${pr}/commits`);
  q("pull_reviews", `/repos/${repo}/pulls/${pr}/reviews`);
  q("user", `/user`);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(`${outDir}api-${side}.json`, JSON.stringify(out, null, 1));
  console.log(`${side}:`, Object.entries(out).map(([k, v]) => `${k}=${v.status}`).join(" "));
}

function shape(v, p, acc) {
  const t = v === null ? "null" : Array.isArray(v) ? "array" : typeof v;
  acc[p || "."] = t;
  if (t === "array" && v.length) shape(v[0], `${p}[]`, acc);
  if (t === "object") for (const k of Object.keys(v)) shape(v[k], p ? `${p}.${k}` : k, acc);
  return acc;
}

// Fields GitHub clients actually rely on; the long tail of GitHub-only cosmetics is ignored.
const IMPORTANT = /(^|\.)(id|node_id|number|state|title|body|html_url|url|name|status|conclusion|head|base|sha|ref|user|login|labels|pull_request|created_at|updated_at|closed_at|workflow_runs|workflow_id|jobs|steps|check_runs|total_count|started_at|completed_at|run_id|run_attempt|head_sha|head_branch|event|merged|draft|mergeable|full_name|private|default_branch|owner|comments|assignees|milestone|state_reason|statuses|context|target_url)$/;

function compare() {
  const g = JSON.parse(readFileSync(side || `${outDir}api-github.json`, "utf8"));
  const d = JSON.parse(readFileSync(other || `${outDir}api-diffinery.json`, "utf8"));
  let problems = 0;
  for (const name of Object.keys(g)) {
    const gs = g[name];
    const ds = d[name];
    const lines = [];
    if (!ds) lines.push("not fetched on the Diffinery side");
    else {
      if (gs.status !== ds.status) lines.push(`HTTP status: GitHub ${gs.status}, Diffinery ${ds.status}`);
      if (typeof gs.body === "object" && typeof ds.body === "object") {
        const a = shape(gs.body, "", {});
        const b = shape(ds.body, "", {});
        for (const [k, t] of Object.entries(a)) {
          if (!IMPORTANT.test(k.replace(/\[\]/g, ""))) continue;
          if (!(k in b)) lines.push(`missing: ${k} (${t})`);
          else if (b[k] !== t && t !== "null" && b[k] !== "null") lines.push(`type: ${k} is ${t} on GitHub, ${b[k]} on Diffinery`);
        }
      } else if (typeof gs.body !== typeof ds.body) lines.push(`body: GitHub ${typeof gs.body}, Diffinery ${typeof ds.body}: ${String(ds.body).slice(0, 120)}`);
    }
    problems += lines.length;
    console.log(`\n## ${name}: ${lines.length ? `${lines.length} difference(s)` : "matches"}`);
    for (const l of lines) console.log(`  - ${l}`);
  }
  console.log(`\nTotal differences in client-relevant fields: ${problems}`);
}

// compare A B: compare any two saved answer files (default: github vs diffinery).
const [cmd, side, other] = process.argv.slice(2);
if (cmd === "fetch") fetchSide(side);
else if (cmd === "compare") compare();
else if (cmd === "all") { fetchSide("github"); fetchSide("diffinery"); compare(); }
else { console.error("usage: apidiff.mjs fetch github|diffinery | compare | all"); process.exit(2); }
