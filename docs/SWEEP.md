# diffhound-sweep

Fallback reviewer that polls GitHub directly for unreviewed PRs, independent
of GitHub Actions. Complements the event-driven workflow, not a replacement.

## When to install this

- An expected event-driven review did not start.
- Runner availability or repo-side throttling has delayed Actions.
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
3. Checks per-`(repo, pr, sha)` state and submitted GitHub reviews for coverage.
4. If not reviewed, not within the grace window, below the attempt limit and within the cycle budget, invokes
   `diffhound <pr> --repo <owner/name> --auto-post`.
5. Records an attempt before invocation and writes `.done` on success.
6. Stops retrying the same SHA after `DIFFHOUND_SWEEP_MAX_ATTEMPTS` (default 3) —
   a new push will reset state because state key includes SHA.

## What it does not do

- It is sequential: a slow review delays later PRs in the batch. A service
  timeout must allow the cycle's launch window plus one invocation deadline and cleanup.
  The defaults stop launching after 15 minutes, bound each invocation to 55 minutes
  plus a 60-second termination grace, and use a 75-minute outer service timeout.
  Lock waiting is part of the invocation deadline and can still consume an attempt.
  GitHub metadata calls have 30-second timeouts; failed reads do not start a review.
- Its default grace window uses PR `updatedAt`, so comment/review activity can
  delay eligibility even without a new commit.
- It does not handle `pull_request_review_comment` (--learn) replies.
  Those still require the event-driven workflow.
- It does not provide distributed locking across hosts or quota management for
  GitHub/model providers. Inspect failed attempts and provider errors before retrying.

## Install

Assumes diffhound is already installed under `$DIFFHOUND_ROOT` on a host
where `gh` is authenticated, `$ANTHROPIC_API_KEY` is exported, and Gemini CLI
authentication is available to the invoking user if both peer slots are needed.

```bash
# 1. List the repos to sweep
mkdir -p ~/.diffhound-sweep
cat > ~/.diffhound-sweep/repos.txt <<EOF
# Repositories to review
owner/backend
owner/frontend
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
TimeoutStartSec=75min
TimeoutStopSec=60s
KillMode=control-group
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

For an existing service, install `config/diffhound-sweep-runtime.conf` as
`/etc/systemd/system/diffhound-sweep.service.d/runtime-budget.conf`, then run
`sudo systemctl daemon-reload`. Preserve existing environment/configuration files.
The next sweep uses the updated cycle logic; do not restart a healthy active review.
If you override the cycle or invocation budget, increase the outer service timeout
to cover their sum, termination grace and metadata overhead.

### Option B: cron

```bash
# crontab -e
*/15 * * * * bash -lc '$HOME/diffhound/bin/diffhound-sweep'
```

Cron inherits a minimal `PATH` and no login shell env — `bash -lc` loads
`~/.profile` / `~/.bash_profile` so `ANTHROPIC_API_KEY` etc. are in scope.
The invocation timeout alone cannot kill descendants that create separate process groups,
including nested model timeouts. Use the systemd service with `KillMode=control-group`
for complete descendant cleanup when a sweep exits, or provide equivalent supervision
for cron. The shell wrapper's termination grace is not a process-tree guarantee.

## Configuration

| Env var                           | Default                    | Purpose |
|-----------------------------------|----------------------------|---------|
| `DIFFHOUND_SWEEP_HOME`            | `$HOME/.diffhound-sweep`   | Config + state + log root |
| `DIFFHOUND_SWEEP_MAX_ATTEMPTS`    | `3`                        | Stop retrying a SHA after N failures |
| `DIFFHOUND_SWEEP_PR_LIMIT`        | `30`                       | `gh pr list --limit` per repo |
| `DIFFHOUND_SWEEP_GRACE_MIN`       | `10`                       | Skip PRs updated within N minutes (lets the event-driven path start first) |
| `DIFFHOUND_BIN`                   | `<repo>/bin/diffhound`     | Path to the diffhound binary |
| `DIFFHOUND_SWEEP_CYCLE_BUDGET_SECONDS` | `900` | Stop starting more work after this many seconds; let an active invocation finish |
| `DIFFHOUND_SWEEP_REVIEW_TIMEOUT_SECONDS` | `3300` | Per-invocation deadline, including lock wait; followed by a 60-second termination grace |

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
    ├── owner_backend_pr123_3a25dd7...attempts
    ├── owner_backend_pr123_3a25dd7...done
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

The single-instance guard recovers when the recorded PID is gone. Inspect that
PID and its current review before intervening. Do not delete the lock directory
while a sweep is alive: that would allow a second sweep to run concurrently.
Use the configured service's stop/cleanup procedure for a confirmed stuck run,
then verify its processes have exited before starting another.

**Every PR fails with `diffhound exit=1`.**

Run the binary manually with the same env to see the real error:
`$HOME/diffhound/bin/diffhound <PR> --repo <owner/name> --auto-post`.
The sweep's own log captures stderr of each invocation.

**Diffhound ran via both sweep and the event-driven workflow — two comments
on the same commit.**

Check that both paths use the same reviewer identity and `DIFFHOUND_LOCK_DIR`
on the same executor. The sweep recognizes submitted reviews, and host-local
PR locks serialize overlapping runs. Separate hosts need external coordination.
Increasing the grace window delays fallback but does not replace coordination.

**A head remains unreviewed after failures stop appearing in the log.**

Inspect its `.attempts` file and earlier errors. After the configured attempt
limit, the sweep stops retrying that SHA. Fix the cause, then either run a
targeted review or back up and reset only that head's attempt marker while the
sweep is stopped. Preserve submitted review history and other PR state.
