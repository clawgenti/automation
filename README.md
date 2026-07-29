# rossoctl/automation

Version-controlled home for rossoctl org automation programs (scanner/fixer pattern).

## Structure

```
scripts/           Program scripts (scanner + fixer per program)
config/            Shared configuration (e.g. core-repos.txt allowlist)
skills/            OpenClaw SKILL.md files per program
standing-orders/   Standing order definitions per program
docs/              Program authoring + self-hosting guides
reports/           (gitignored) Runtime data stays on remote host only
```

## Programs

| Program | Scanner | Fixer | Notes |
|---------|---------|-------|-------|
| Link Health | `scripts/link-health-scanner.sh` | `scripts/link-health-fixer.sh` | Detects broken links, files issues, and opens fix PRs. Epic [#1178](https://github.com/rossoctl/rossoctl/issues/1178) |
| PR Review | `scripts/pr-review-scanner.sh` | `scripts/pr-review-fixer.sh` | Scanner finds PRs labeled for review; fixer performs the AI review (posts review + inline comments, advances the review-state label). `scripts/pr-review-impact.sh` measures time-to-merge impact |
| Dependency Bump | `scripts/dep-bump-scanner.sh` | `scripts/dep-bump-fixer.sh` | Tracks and triages Dependabot PRs across repos (comments, closes stale, audits coverage) |
| Health Dashboard | `scripts/automation-health-dashboard.sh` | — | Aggregates program run health into a dashboard |

Shared helpers live in `scripts/program-lib.sh`. Repo coverage comes from the `config/core-repos.txt` allowlist via `get_core_repos()` (one `owner/name` per line; `#` comments and blank lines allowed) -- edit that file to change which repos are scanned.

## Deploy

Scripts run on the remote host (`kagenti-bot:~/workspaces/clawgenti/scripts/`).
Deploy after merging changes:

```bash
scp scripts/<name>.sh kagenti-bot:~/workspaces/clawgenti/scripts/
```

No gateway restart needed -- scripts are read from disk on each cron trigger.

Scanners/fixers that use the allowlist also require `config/core-repos.txt` to be present on the host alongside the scripts:

```bash
scp config/core-repos.txt kagenti-bot:~/workspaces/clawgenti/config/
```

## Runtime

- Reports: `~/workspaces/clawgenti/reports/<program>/` (remote host only) -- one directory per program.
- Cron jobs managed via OpenClaw gateway (`~/.openclaw/cron/jobs.json`).
- Bot account: [clawgenti](https://github.com/clawgenti).

See `docs/running-without-openclaw.md` to run the programs outside OpenClaw, and `docs/program-template.md` to author a new program.
