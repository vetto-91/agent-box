#!/bin/bash
set -euo pipefail

# 1. Prepara bundle CA dinamico in /tmp (compatibile con rootfs read-only e certificati self-signed)
CA_BUNDLE="/tmp/ca-certificates.crt"
cp -f /etc/ssl/certs/ca-certificates.crt "${CA_BUNDLE}"
if [ -d /etc/agent-box/certs ]; then
    CUSTOM_CA_COUNT=0
    for cert in /etc/agent-box/certs/*.crt /etc/agent-box/certs/*.pem; do
        if [ -f "${cert}" ]; then
            printf '\n' >> "${CA_BUNDLE}"
            cat "${cert}" >> "${CA_BUNDLE}"
            CUSTOM_CA_COUNT=$((CUSTOM_CA_COUNT + 1))
        fi
    done
    if [ "${CUSTOM_CA_COUNT}" -gt 0 ]; then
        echo "[agent-box] Caricati ${CUSTOM_CA_COUNT} certificati CA personalizzati da ./certs in ${CA_BUNDLE}"
    fi
fi
chmod 0644 "${CA_BUNDLE}"

# 2. Prepara le directory utente nel volume persistente /home/agent
if ! mkdir -p \
    "${HOME}/.cargo/bin" \
    "${HOME}/.local/share/keyrings" \
    "${HOME}/.npm-global/bin" \
    "${HOME}/.local/bin" \
    "${HOME}/.cache/npm" \
    "${HOME}/.cache/uv" \
    "${HOME}/.config/opencode" \
    "${HOME}/.pi/agent" \
    "${HOME}/.codex" \
    "${HOME}/.gemini" 2>/dev/null; then
    echo "[agent-box] ATTENZIONE: /home/agent non è scrivibile da $(id -u):$(id -g) (probabile mismatch UID/GID in ./agent-home)."
    echo "[agent-box] Uso fallback temporaneo in /tmp/agent-home (esegui ./agent-box.sh per correggere automaticamente i permessi di ./agent-home)."
    export HOME="/tmp/agent-home"
    mkdir -p \
        "${HOME}/.cargo/bin" \
        "${HOME}/.local/share/keyrings" \
        "${HOME}/.npm-global/bin" \
        "${HOME}/.local/bin" \
        "${HOME}/.cache/npm" \
        "${HOME}/.cache/uv" \
        "${HOME}/.config/opencode" \
        "${HOME}/.pi/agent" \
        "${HOME}/.codex" \
        "${HOME}/.gemini"
fi

# 3. Configura prompt sandbox e supporto TLS opzionale in .bashrc
if [ ! -f "${HOME}/.bashrc" ] || ! grep -q "AGENT-BOX" "${HOME}/.bashrc" 2>/dev/null; then
    cat <<'EOF' >> "${HOME}/.bashrc"

# --- AGENT-BOX SANDBOX PROMPT ---
export PS1='\[\033[1;31m\][🔒 agent-box]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ '
alias ll='ls -la --color=auto'
EOF
fi

# 4. Configurazione automatica modelli locali (OpenCode, Pi Agent, Codex)
LOCAL_URL="${LOCAL_LLM_BASE_URL:-}"
LOCAL_KEY="${LOCAL_LLM_API_KEY:-local}"
LOCAL_MODEL="${LOCAL_LLM_MODEL:-qwen2.5-coder:latest}"
LOCAL_NAME="${LOCAL_LLM_NAME:-Local LLM}"

# 4a. OpenCode (~/.config/opencode/opencode.json)
if [ ! -f "${HOME}/.config/opencode/opencode.json" ] || [ "${AGENT_REGENERATE_LOCAL_CONFIG:-0}" = "1" ]; then
    if [ -n "${OLLAMA_HOST:-}" ] || [ -n "${LOCAL_URL}" ]; then
        jq -n \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg local_url "${LOCAL_URL}" \
            --arg local_key "${LOCAL_KEY}" \
            --arg local_model "${LOCAL_MODEL}" \
            --arg local_name "${LOCAL_NAME}" '
            {"$schema": "https://opencode.ai/config.json", "provider": {}}
            | if $ollama_url != "" then
                .provider.ollama = {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Ollama (Local)",
                    "options": {"baseURL": ($ollama_url + "/v1")},
                    "models": {}
                }
              else . end
            | if $local_url != "" then
                .provider.local = {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": $local_name,
                    "options": {"baseURL": $local_url, "apiKey": $local_key},
                    "models": { ($local_model): {"name": $local_model} }
                }
              else . end
        ' > "${HOME}/.config/opencode/opencode.json"
    fi
fi

# 4b. Pi Agent (~/.pi/agent/models.json)
if [ ! -f "${HOME}/.pi/agent/models.json" ] || [ "${AGENT_REGENERATE_LOCAL_CONFIG:-0}" = "1" ]; then
    if [ -n "${OLLAMA_HOST:-}" ] || [ -n "${LOCAL_URL}" ]; then
        jq -n \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg local_url "${LOCAL_URL}" \
            --arg local_key "${LOCAL_KEY}" \
            --arg local_model "${LOCAL_MODEL}" '
            {"providers": {}}
            | if $ollama_url != "" then
                .providers.ollama = {
                    "baseUrl": ($ollama_url + "/v1"),
                    "api": "openai-completions",
                    "apiKey": "ollama",
                    "models": [{"id": $local_model}]
                }
              else . end
            | if $local_url != "" then
                .providers.local = {
                    "baseUrl": $local_url,
                    "api": "openai-completions",
                    "apiKey": $local_key,
                    "models": [{"id": $local_model}]
                }
              else . end
        ' > "${HOME}/.pi/agent/models.json"
    fi
fi

# 4c. OpenAI Codex (~/.codex/config.toml) - profilo "local" se LOCAL_LLM_BASE_URL è impostato
if [ -n "${LOCAL_URL}" ] && { [ ! -f "${HOME}/.codex/config.toml" ] || [ "${AGENT_REGENERATE_LOCAL_CONFIG:-0}" = "1" ]; }; then
    cat <<EOF > "${HOME}/.codex/config.toml"
[model_providers.local]
name = "${LOCAL_NAME}"
base_url = "${LOCAL_URL}"
env_key = "LOCAL_LLM_API_KEY"

[profiles.local]
model_provider = "local"
model = "${LOCAL_MODEL}"
EOF
fi

exec "$@"
