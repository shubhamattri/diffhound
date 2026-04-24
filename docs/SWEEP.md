# diffhound-sweep

Fallback reviewer that polls GitHub directly for unreviewed PRs, independent
of GitHub Actions. Complements the event-driven workflow, not a replacement.

## When to install this

- Your event-driven `pull_request` workflow occasionally misses pushes
  (GitHub Actions drops webhooks a few times a year even in healthy orgs).
- Repo-side throttling has previously paused Actions for an extended window
  (reference: monorepo 2026-04-23 incident).
- Your runner crashes mid-review leaving no comment on the PR.
- The diffhound binary itself crashed on a specific commit — a new push
  should automatically retry.

## What it does

Every N minutes (you pick via cron/systemd timer), sweep:

1. Loads `repos.txt`. One `owner/name` per line.
2. For each repo, calls `gh pr list --state open` and filters to:
   - `isDraft == false`
   - `author.is_bot != true` — covers Dependabot, Renovate, GitHub App actors
   - Title does not contain `[skip review]`
3. For each qualifying PR, checks a per-`(repo, pr, sha)` state file.
4. If not reviewed and not within the grace window, invokes
   `diffhound <pr> --repo <owner/name> --auto-post`.
5. Writes `.done` on success, increments `.attempts` on failure.
6. Stops retrying the same SHA after `DIFFHOUND_SWEEP_MAX_ATTEMPTS` (default 3) —
   a new push will reset state because state key includes SHA.

## What it does not do

- It does not detect whether the event-driven workflow already posted a
  review. It relies on the grace window to dodge that race; see
  `DIFFHOUND_SWEEP_GRACE_MIN`. Worst case: one duplicate review comment.
- It does not handle `pull_request_review_comment` (--learn) replies.
  Those still require the event-driven workflow.
- It does not guard against API rate limits. At default cadence
  (every 15 min × 3 repos × ~10 PRs) you are not close to rate limits.

## Install

Assumes diffhound is already installed under `$DIFFHOUND_ROOT` on a host
where `gh` is authenticated and `$ANTHROPIC_API_KEY` (plus any Codex/Gemini
keys you use) are available to the invoking user.

```bash
# 1. List the repos to sweep
mkdir -p ~/.diffhound-sweep
cat > ~/.diffhound-sweep/repos.txt <<EOF
# Nova diffhound-consumer repos
NovaBenefits/monorepo
NovaBenefits/reco
NovaBenefits/domain-setup-tool
EOF

# 2. Pick one of: systemd timer (preferred) or cron
```

### Option A: systemd timer (preferred)

```ini
# /etc/systemd/system/diffhound-sweep.service
[Unit]
Description=diffhound fallback sweep
After=network-online.target

[Service]
Type=oneshot
User=ubuntu
EnvironmentFile=/home/ubuntu/.diffhound-sweep/env
ExecStart=/home/ubuntu/diffhound/bin/diffhound-sweep
Nice=10
```

```ini
# /etc/systemd/system/diffhound-sweep.timer
[Unit]
Description=diffhound sweep every 15 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
# EnvironmentFile picks up anything the event-driven workflow would need:
cat > ~/.diffhound-sweep/env <<EOF
ANTHROPIC_API_KEY=...
PATH=/home/ubuntu/.local/bin:/home/ubuntu/diffhound-venv/bin:/usr/local/bin:/usr/bin:/bin
EOF
chmod 600 ~/.diffhound-sweep/env

sudo systemctl daemon-reload
sudo systemctl enable --now diffhound-sweep.timer
systemctl list-timers diffhound-sweep.timer
```

### Option B: cron

```bash
# crontab -e
*/15 * * * * bash -lc '$HOME/diffhound/bin/diffhound-sweep'
```

Cron inherits a minimal `PATH` and no login shell env — `bash -lc` loads
`~/.profile` / `~/.bash_profile` so `ANTHROPIC_API_KEY` etc. are in scope.

## Configuration

| Env var                           | Default                    | Purpose |
|-----------------------------------|----------------------------|---------|
| `DIFFHOUND_SWEEP_HOME`            | `$HOME/.diffhound-sweep`   | Config + state + log root |
| `DIFFHOUND_SWEEP_MAX_ATTEMPTS`    | `3`                        | Stop retrying a SHA after N failures |
| `DIFFHOUND_SWEEP_PR_LIMIT`        | `30`                       | `gh pr list --limit` per repo |
| `DIFFHOUND_SWEEP_GRACE_MIN`       | `10`                       | Skip commits younger than N min (lets the event-driven path win) |
| `DIFFHOUND_BIN`                   | `<repo>/bin/diffhound`     | Path to the diffhound binary |

`repos.txt` supports blank lines and `#` comments.

## State layout

```
~/.diffhound-sweep/
├── repos.txt                          # you own this
├── env                                # you own this (systemd only)
├── sweep.log                          # append-only
├── sweep.lock/                        # single-instance guard (dir)
│   └── pid
└── state/
    ├── NovaBenefits_monorepo_pr7054_3a25dd7...attempts
    ├── NovaBenefits_monorepo_pr7054_3a25dd7...done
    └── ...
```

The sweep prunes state files older than 30 days on each run, so closed
and merged PRs don't accumulate.

## Observability

- `journalctl -u diffhound-sweep.service` — per-run output (systemd).
- `tail -f ~/.diffhound-sweep/sweep.log` — combined log across runs.
- Each log line is prefixed with `[UTC timestamp]` so grep-by-day works.

## Troubleshooting

**Sweep says "another sweep is running" forever.**

The single-instance guard self-heals: if the recorded pid is gone it
breaks the lock. If the holder is truly alive and stuck, bounce it:
`rm -rf ~/.diffhound-sweep/sweep.lock`.

**Every PR fails with `diffhound exit=1`.**

Run the binary manually with the same env to see the real error:
`$HOME/diffhound/bin/diffhound <PR> --repo <owner/name> --auto-post`.
The sweep's own log captures stderr of each invocation.

**Diffhound ran via both sweep and the event-driven workflow — two comments
on the same commit.**

Increase `DIFFHOUND_SWEEP_GRACE_MIN` (e.g. to `20` or `30`). The grace
window is deliberately conservative because it's the only defence against
the race; raising it trades fallback latency for fewer duplicates.
