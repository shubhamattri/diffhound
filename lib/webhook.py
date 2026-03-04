#!/usr/bin/env python3
"""
Diffhound Webhook Server
Listens for GitHub webhooks and triggers automated PR reviews.

Events handled:
  - pull_request.opened          → full review (--auto-post)
  - pull_request.synchronize     → fast re-review (--fast --auto-post)
  - pull_request_review_comment  → fast re-review on dev replies

Deployment:
  gunicorn -w 1 -b 0.0.0.0:8090 --timeout 600 webhook:app
"""

import os
import sys
import hmac
import hashlib
import subprocess
import threading
import time
import logging
from pathlib import Path
from flask import Flask, request, jsonify

# ── Logging ──────────────────────────────────────────────────
LOG_DIR = Path(os.environ.get("DIFFHOUND_LOG_DIR", os.path.expanduser("~/logs/pr-reviews")))
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "webhook.log"),
    ],
)
logger = logging.getLogger("diffhound-webhook")

app = Flask(__name__)

# ── Config ───────────────────────────────────────────────────
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET")
if not WEBHOOK_SECRET or WEBHOOK_SECRET == "change-me-in-production":
    logger.error("WEBHOOK_SECRET not set! export WEBHOOK_SECRET='...'")
    sys.exit(1)

DIFFHOUND_BIN = os.environ.get(
    "DIFFHOUND_BIN", os.path.expanduser("~/diffhound/bin/diffhound")
)
REPO_PATH = os.environ.get("REVIEW_REPO_PATH", os.path.expanduser("~/monorepo"))
REVIEWER_LOGIN = os.environ.get("REVIEW_LOGIN", "")

MAX_CONCURRENT = int(os.environ.get("DIFFHOUND_MAX_CONCURRENT", "2"))
DEBOUNCE_SECONDS = int(os.environ.get("DIFFHOUND_DEBOUNCE_SECONDS", "60"))

# ── State ────────────────────────────────────────────────────
# Idempotency: track processed delivery IDs
processed_deliveries: set[str] = set()
MAX_TRACKED = 2000

# Concurrency: track running reviews
_active_lock = threading.Lock()
_active_reviews: dict[int, subprocess.Popen] = {}

# Debounce: track last synchronize event per PR
_debounce_lock = threading.Lock()
_debounce_timers: dict[int, threading.Timer] = {}


# ── Helpers ──────────────────────────────────────────────────
def verify_signature(payload: bytes, signature: str | None) -> bool:
    if not signature:
        return False
    try:
        sha_name, sig_hash = signature.split("=", 1)
    except ValueError:
        return False
    if sha_name != "sha256":
        return False
    mac = hmac.new(WEBHOOK_SECRET.encode(), msg=payload, digestmod=hashlib.sha256)
    return hmac.compare_digest(mac.hexdigest(), sig_hash)


def sync_repo():
    """Pull latest origin/master so Claude has current codebase context."""
    try:
        subprocess.run(
            ["git", "-C", REPO_PATH, "fetch", "origin"],
            capture_output=True, timeout=30,
        )
        subprocess.run(
            ["git", "-C", REPO_PATH, "checkout", "origin/master", "-f"],
            capture_output=True, timeout=30,
        )
        logger.info("Repo synced to origin/master")
    except Exception as e:
        logger.warning(f"Repo sync failed (non-fatal): {e}")


def should_skip_pr(pr_data: dict) -> str | None:
    """Return skip reason, or None if review should proceed."""
    if pr_data.get("draft", False):
        return "Draft PR"

    title = pr_data.get("title", "").lower()
    skip_keywords = ["wip", "[skip review]", "deps:", "chore(deps)", "[skip ci]"]
    if any(kw in title for kw in skip_keywords):
        return f"Skip keyword in title: {title}"

    if pr_data.get("changed_files", 0) == 0:
        return "No files changed"

    return None


def run_review(pr_number: int, fast: bool, delivery_id: str):
    """Execute diffhound in a subprocess. Blocks until complete."""
    # Enforce concurrency limit
    with _active_lock:
        if len(_active_reviews) >= MAX_CONCURRENT:
            logger.warning(
                f"Concurrency limit ({MAX_CONCURRENT}) reached, skipping PR #{pr_number}"
            )
            return

    sync_repo()

    cmd = [DIFFHOUND_BIN, str(pr_number), "--auto-post"]
    if fast:
        cmd.append("--fast")

    log_file = LOG_DIR / f"pr-{pr_number}-{delivery_id[:8]}.log"
    logger.info(f"Starting review: {' '.join(cmd)} → {log_file}")

    env = {
        **os.environ,
        "REVIEW_REPO_PATH": REPO_PATH,
        "REVIEW_LOGIN": REVIEWER_LOGIN,
        "PR_DELIVERY_ID": delivery_id,
    }

    try:
        with open(log_file, "w") as fh:
            proc = subprocess.Popen(
                cmd,
                stdout=fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                env=env,
            )
        with _active_lock:
            _active_reviews[pr_number] = proc

        logger.info(f"Review running for PR #{pr_number} (PID {proc.pid})")
        proc.wait()  # Block thread until review finishes
        logger.info(
            f"Review finished for PR #{pr_number} (exit {proc.returncode})"
        )
    except Exception as e:
        logger.error(f"Review failed for PR #{pr_number}: {e}")
    finally:
        with _active_lock:
            _active_reviews.pop(pr_number, None)


def trigger_review(pr_number: int, fast: bool, delivery_id: str):
    """Fire-and-forget: launch review in a background thread."""
    t = threading.Thread(
        target=run_review,
        args=(pr_number, fast, delivery_id),
        daemon=True,
        name=f"review-pr-{pr_number}",
    )
    t.start()


def debounced_trigger(pr_number: int, delivery_id: str):
    """Debounce synchronize events: wait DEBOUNCE_SECONDS, run only the last one."""
    with _debounce_lock:
        existing = _debounce_timers.pop(pr_number, None)
        if existing:
            existing.cancel()
            logger.info(f"Debounce: cancelled previous timer for PR #{pr_number}")

        timer = threading.Timer(
            DEBOUNCE_SECONDS,
            trigger_review,
            args=(pr_number, True, delivery_id),
        )
        _debounce_timers[pr_number] = timer
        timer.start()
        logger.info(
            f"Debounce: scheduled review for PR #{pr_number} in {DEBOUNCE_SECONDS}s"
        )


def track_delivery(delivery_id: str):
    processed_deliveries.add(delivery_id)
    if len(processed_deliveries) > MAX_TRACKED:
        # Discard oldest (set is unordered, but good enough)
        processed_deliveries.pop()


# ── Routes ───────────────────────────────────────────────────
@app.route("/webhook", methods=["POST"])
def webhook():
    # Verify signature
    signature = request.headers.get("X-Hub-Signature-256")
    if not verify_signature(request.data, signature):
        logger.warning(f"Invalid signature from {request.remote_addr}")
        return jsonify({"error": "Invalid signature"}), 401

    # Idempotency
    delivery_id = request.headers.get("X-GitHub-Delivery", "unknown")
    if delivery_id in processed_deliveries:
        return jsonify({"message": "Already processed"}), 200

    event = request.headers.get("X-GitHub-Event")
    payload = request.get_json(silent=True)
    if not payload:
        return jsonify({"error": "Invalid payload"}), 400

    # ── pull_request events ──────────────────────────────────
    if event == "pull_request":
        action = payload.get("action")
        pr_data = payload.get("pull_request", {})
        pr_number = pr_data.get("number")

        if not pr_number:
            return jsonify({"error": "Missing PR number"}), 400

        skip_reason = should_skip_pr(pr_data)
        if skip_reason:
            logger.info(f"Skipping PR #{pr_number}: {skip_reason}")
            return jsonify({"message": f"Skipped: {skip_reason}"}), 200

        track_delivery(delivery_id)

        if action == "opened":
            # Full review on new PR
            logger.info(f"PR #{pr_number} opened — triggering full review")
            trigger_review(pr_number, fast=False, delivery_id=delivery_id)
            return jsonify({"message": "Full review triggered", "pr": pr_number}), 200

        elif action == "synchronize":
            # New commits pushed — debounced fast review
            logger.info(f"PR #{pr_number} synchronized — debouncing fast review")
            debounced_trigger(pr_number, delivery_id)
            return jsonify({"message": "Fast review scheduled (debounced)", "pr": pr_number}), 200

        else:
            return jsonify({"message": f"Ignoring action: {action}"}), 200

    # ── pull_request_review_comment events ───────────────────
    if event == "pull_request_review_comment":
        action = payload.get("action")
        if action != "created":
            return jsonify({"message": f"Ignoring comment action: {action}"}), 200

        comment = payload.get("comment", {})
        commenter = comment.get("user", {}).get("login", "")
        pr_data = payload.get("pull_request", {})
        pr_number = pr_data.get("number")

        if not pr_number:
            return jsonify({"error": "Missing PR number"}), 400

        # Only re-review when a dev (not the reviewer bot) comments
        if commenter == REVIEWER_LOGIN:
            return jsonify({"message": "Ignoring own comment"}), 200

        skip_reason = should_skip_pr(pr_data)
        if skip_reason:
            return jsonify({"message": f"Skipped: {skip_reason}"}), 200

        track_delivery(delivery_id)
        logger.info(
            f"Dev reply on PR #{pr_number} by @{commenter} — triggering fast re-review"
        )
        debounced_trigger(pr_number, delivery_id)
        return jsonify({"message": "Re-review scheduled", "pr": pr_number}), 200

    # ── Unhandled events ─────────────────────────────────────
    return jsonify({"message": f"Ignoring event: {event}"}), 200


@app.route("/health", methods=["GET"])
def health():
    bin_exists = os.path.isfile(DIFFHOUND_BIN)
    bin_executable = os.access(DIFFHOUND_BIN, os.X_OK) if bin_exists else False

    with _active_lock:
        active = {pr: p.pid for pr, p in _active_reviews.items()}

    with _debounce_lock:
        pending = list(_debounce_timers.keys())

    status = "healthy" if (bin_exists and bin_executable) else "degraded"
    return jsonify({
        "status": status,
        "version": "diffhound-webhook-v1",
        "diffhound_bin": DIFFHOUND_BIN,
        "bin_ok": bin_exists and bin_executable,
        "repo_path": REPO_PATH,
        "reviewer_login": REVIEWER_LOGIN,
        "active_reviews": active,
        "pending_debounce": pending,
        "max_concurrent": MAX_CONCURRENT,
        "debounce_seconds": DEBOUNCE_SECONDS,
        "processed_count": len(processed_deliveries),
    }), 200 if status == "healthy" else 503


@app.route("/metrics", methods=["GET"])
def metrics():
    return jsonify({
        "processed_deliveries": len(processed_deliveries),
        "log_files": len(list(LOG_DIR.glob("pr-*.log"))),
        "active_reviews": len(_active_reviews),
        "version": "diffhound-webhook-v1",
    }), 200


if __name__ == "__main__":
    logger.warning("Dev mode — use gunicorn for production!")
    logger.info(f"Diffhound bin: {DIFFHOUND_BIN}")
    logger.info(f"Repo path:     {REPO_PATH}")
    logger.info(f"Reviewer:      {REVIEWER_LOGIN}")
    logger.info(f"Max concurrent: {MAX_CONCURRENT}")
    logger.info(f"Debounce:      {DEBOUNCE_SECONDS}s")
    logger.info("Endpoints: POST /webhook | GET /health | GET /metrics")
    app.run(host="0.0.0.0", port=8090, debug=False)
