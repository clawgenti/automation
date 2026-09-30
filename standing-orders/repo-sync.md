## Program: Repo Sync

**Authority:** Keep the local repository clones current so the scanner/fixer
programs operate on up-to-date working copies.
**Trigger:** Daily (enforced via cron job `repo-sync`).
**Approval gate:** None (read-only clone/pull; no writes to GitHub).
**Escalation:** None while any repo still syncs. A repo that fails to clone or
pull is logged and the sync continues with the rest. Only a run in which *every*
enrolled repo failed exits non-zero (a total failure must not look like success).

### Scope
- The enrolled repo set recorded in `~/.repoman/repos.json`, not the live
  `gh repo list <org>` output. Enrollment is the source of truth for which
  repos the suite operates on.
- For each enrolled `owner/name`, clones it into `<repos_dir>/<owner>/<name>/`
  if missing, because clone dirs are namespaced by owner. If the clone already
  exists, runs `git pull --ff-only` to bring it current.

### What NOT to Do
- Do not push, open PRs, or otherwise write to any GitHub repo.
- Do not delete or reset local clones with uncommitted state. Pull only.
- Do not clone or pull a repo outside the enrolled set in `~/.repoman/repos.json`.
- Do not act on an enrolled entry whose owner or name is not a single safe path
  segment (`[A-Za-z0-9._-]`, never `.`/`..`/a slash). Such an entry is rejected
  and logged, never cloned, so a crafted `repos.json` cannot escape the clone tree.

### Operational Notes
- Cron job: `repo-sync` (daily, isolated).
- A per-repo clone, pull, directory-creation, or validation failure is logged
  and non-fatal, so the sync continues with the rest of the enrolled set — as
  long as at least one repo succeeds, the run exits 0. If *every* enrolled repo
  fails, the run exits non-zero. A failure to read the config or the
  enrolled-repos file is fail-loud, because those are prerequisites for the
  whole run.
- The optional `--refresh-skills` flag (or the `REPOMAN_SKILLS_DIR`
  environment variable) also pulls a local agent-skills clone. A missing
  skills clone is a fatal error, because repo-sync does not bootstrap it.
