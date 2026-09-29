#!/usr/bin/env python3
"""Serialize CLI/Action/sweep reviews for a PR on one host, including crashes."""
import fcntl
import hashlib
import os
from pathlib import Path
import sys
import re
import subprocess
from urllib.parse import urlparse


def acquire(identity, directory):
    """Return a lock descriptor that survives exec and is released on exit."""
    directory.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(identity.encode()).hexdigest() + ".lock"
    fd = os.open(directory / name, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.set_inheritable(fd, True)
    return fd


def repository_identity(args):
    """Both --repo and a profile-configured checkout use the remote owner/name."""
    repo = os.environ.get("REVIEW_REPO_PATH", str(Path.cwd()))
    slug = None
    for index, arg in enumerate(args):
        if arg == "--repo" and index + 1 < len(args):
            slug = args[index + 1]
        elif arg.startswith("--repo="):
            slug = arg[7:]
    host = os.environ.get("GH_HOST", "github.com").lower()
    if slug is None:
        remote = subprocess.run(["git", "-C", repo, "remote", "get-url", "origin"],
                                capture_output=True, text=True, check=True).stdout.strip()
        if "://" not in remote:
            remote = "ssh://" + remote.replace(":", "/", 1)
        parsed = urlparse(remote)
        if parsed.hostname != host:
            raise ValueError("Checkout remote does not match the configured GitHub host")
        slug = parsed.path.strip("/").removesuffix(".git")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", slug):
        raise ValueError("Cannot determine repository identity for the review lock")
    return host + "/" + slug.lower()


def main():
    args = sys.argv[1:]
    directory = Path(os.environ.get("DIFFHOUND_LOCK_DIR", str(Path.home() / ".cache/diffhound/locks")))
    acquire(repository_identity(args) + "/" + (args[0] if args else "help"), directory)
    os.environ["DIFFHOUND_REVIEW_LOCKED"] = "1"
    script = Path(__file__).with_name("review.sh")
    os.execvp("bash", ["bash", str(script), *args])


if __name__ == "__main__":
    main()
