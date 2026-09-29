## Program: Repo Sync

**Authority:** Keep the local repository clones current so the scanner/fixer
programs operate on up-to-date working copies.
**Trigger:** Daily (enforced via cron job `repo-sync`).
**Approval gate:** None (read-only clone/pull; no writes to GitHub).
**Escalation:** None. A repo that fails to clone or pull is logged; the sync
continues with the rest.

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

### Operational Notes
- Cron job: `repo-sync` (daily, isolated).
- A per-repo clone, pull, or directory-creation failure is logged and
  non-fatal, so the sync continues with the rest of the enrolled set. A
  failure to read the config or the enrolled-repos file is fail-loud, because
  those are prerequisites for the whole run.
- The optional `--refresh-skills` flag (or the `REPOMAN_SKILLS_DIR`
  environment variable) also pulls a local agent-skills clone. A missing
  skills clone is a fatal error, because repo-sync does not bootstrap it.
