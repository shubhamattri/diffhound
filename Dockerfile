# syntax=docker/dockerfile:1.6
# Diffhound — AI-powered PR code review, containerized for CI.
#
# Image contains: diffhound + gh + jq + gawk + gitleaks + claude/codex/gemini CLIs.
# Intended use: as a `docker://ghcr.io/shubhamattri/diffhound:<tag>` step in consumer workflows.

FROM node:20-bookworm-slim

ARG GITLEAKS_VERSION=8.21.2

# ── System deps ────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      gnupg \
      gawk \
      jq \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# ── gitleaks (pinned) ──────────────────────────────────────
RUN curl -fsSL -o /tmp/gitleaks.tgz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  && tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \
  && rm /tmp/gitleaks.tgz \
  && gitleaks version

# ── LLM CLIs (claude fallback, codex + gemini peer review) ─
# Unpinned initially; pin once image has been validated under real load.
RUN npm install -g --omit=dev \
      @anthropic-ai/claude-code \
      @openai/codex \
      @google/gemini-cli \
  && npm cache clean --force

# ── Diffhound source (from repo context at build time) ─────
COPY . /opt/diffhound
RUN chmod +x /opt/diffhound/bin/diffhound /opt/diffhound/lib/*.sh \
  && ln -s /opt/diffhound/bin/diffhound /usr/local/bin/diffhound

# ── Non-root runtime ───────────────────────────────────────
RUN useradd -m -u 1001 -s /bin/bash runner \
  && chown -R runner:runner /opt/diffhound
USER runner

WORKDIR /github/workspace
ENTRYPOINT ["/usr/local/bin/diffhound"]
