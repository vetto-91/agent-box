FROM ubuntu:26.04

ARG PUID=1000
ARG PGID=1000
ARG INSTALL_AIDER_AT_BUILD=0
ARG INSTALL_HERMES_AT_BUILD=0

LABEL agentbox.uid="${PUID}" \
      agentbox.gid="${PGID}" \
      agentbox.base="ubuntu26.04" \
      agentbox.version="3"

ENV DEBIAN_FRONTEND=noninteractive

# 1. Strumenti base di sistema per agenti di coding
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
    ripgrep \
    fd-find \
    jq \
    tmux \
    less \
    nano \
    vim-tiny \
    procps \
    iputils-ping \
    bind9-dnsutils \
    build-essential \
    nodejs \
    npm \
    xauth \
    libx11-6 \
    libx11-xcb1 \
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libxcb1 \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    libwayland-client0 \
    libwayland-egl1 \
    libwayland-cursor0 \
    libgl1 \
    libgl1-mesa-dri \
    libegl1 \
    libgles2 \
    libgbm1 \
    libdrm2 \
    libva2 \
    libva-drm2 \
    libvulkan1 \
    mesa-vulkan-drivers \
    libnss3 \
    libasound2t64 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# 2. Installa uv (package/tool manager Python velocissimo per Aider e ambienti virtuali)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

# 3. Pre-installa CLI degli agenti AI globalmente in /usr/local
#    (Claude Code, OpenCode, OpenAI Codex/ChatGPT, xAI Grok, Gemini CLI, Pi Agent)
RUN npm install -g \
    @anthropic-ai/claude-code \
    opencode-ai \
    @openai/codex \
    @xai-official/grok \
    @google/gemini-cli \
    @mariozechner/pi-coding-agent \
    && npm cache clean --force

# 3b. Installa Antigravity CLI (agy) se raggiungibile al build, altrimenti wrapper lazy al primo avvio
RUN (curl -fsSL https://antigravity.google/cli/install.sh | env HOME=/opt/agy-install bash && \
     if [ -x /opt/agy-install/.local/bin/agy ]; then \
         mv /opt/agy-install/.local/bin/agy /usr/local/bin/agy; \
     fi && \
     rm -rf /opt/agy-install) || true
RUN if [ ! -x /usr/local/bin/agy ]; then \
        printf '#!/bin/sh\nset -e\nif [ ! -x "$HOME/.local/bin/agy" ]; then\n  echo "[agent-box] Prima esecuzione di Antigravity CLI (agy): installazione in $HOME/.local..."\n  curl -fsSL https://antigravity.google/cli/install.sh | bash\nfi\nexec "$HOME/.local/bin/agy" "$@"\n' > /usr/local/bin/agy && \
        chmod +x /usr/local/bin/agy; \
    fi

# 4. Wrapper intelligente per Aider (lo pre-installa al build se richiesto,
#    oppure al primo avvio nel volume persistente /home/agent/.local usando uv)
RUN if [ "${INSTALL_AIDER_AT_BUILD}" = "1" ]; then \
        PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install aider-chat; \
    else \
        printf '#!/bin/sh\nset -e\nif [ ! -x "$HOME/.local/bin/aider" ]; then\n  echo "[agent-box] Prima esecuzione di Aider: installazione in $HOME/.local tramite uv..."\n  uv tool install --python python3 aider-chat\nfi\nexec "$HOME/.local/bin/aider" "$@"\n' > /usr/local/bin/aider && \
        chmod +x /usr/local/bin/aider; \
    fi

# 4b. Wrapper intelligente per Hermes Agent (Nous Research)
RUN if [ "${INSTALL_HERMES_AT_BUILD}" = "1" ]; then \
        PIPX_HOME=/opt/pipx-hermes PIPX_BIN_DIR=/usr/local/bin pipx install hermes-agent; \
    else \
        printf '#!/bin/sh\nset -e\nif [ ! -x "$HOME/.local/bin/hermes" ]; then\n  echo "[agent-box] Prima esecuzione di Hermes Agent: installazione in $HOME/.local tramite uv..."\n  uv tool install --python python3 hermes-agent\nfi\nexec "$HOME/.local/bin/hermes" "$@"\n' > /usr/local/bin/hermes && \
        chmod +x /usr/local/bin/hermes; \
    fi

# 5. Crea utente non-root "agent" con UID/GID corrispondenti all'utente host
RUN (userdel -r ubuntu 2>/dev/null || true) && \
    (groupdel ubuntu 2>/dev/null || true) && \
    groupadd -g "${PGID}" -o agent && \
    useradd -m -u "${PUID}" -g "${PGID}" -o -s /bin/bash agent && \
    mkdir -p /workspace /home/agent/.npm-global /home/agent/.local/bin /home/agent/.cache && \
    chown -R "${PUID}:${PGID}" /workspace /home/agent

# Variabili d'ambiente per permettere installazioni utente anche con rootfs read-only
ENV HOME=/home/agent \
    USER=agent \
    NPM_CONFIG_PREFIX=/home/agent/.npm-global \
    NPM_CONFIG_CACHE=/home/agent/.cache/npm \
    UV_CACHE_DIR=/home/agent/.cache/uv \
    UV_TOOL_DIR=/home/agent/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/home/agent/.local/bin \
    PIPX_HOME=/home/agent/.local/pipx \
    PIPX_BIN_DIR=/home/agent/.local/bin \
    SSL_CERT_FILE=/tmp/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/tmp/ca-certificates.crt \
    CURL_CA_BUNDLE=/tmp/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/tmp/ca-certificates.crt \
    PATH="/home/agent/.npm-global/bin:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${PUID}:${PGID}
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
