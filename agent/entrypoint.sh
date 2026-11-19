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

# 5. Avvio server PulseAudio isolato nel container (nessun accesso diretto al socket PulseAudio dell'host)
if [ "${AGENT_AUDIO:-1}" = "1" ] && command -v pulseaudio >/dev/null 2>&1; then
    RUNTIME_USER_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    mkdir -p "${RUNTIME_USER_DIR}/pulse" /run/agent-audio 2>/dev/null || true
    rm -f /run/agent-audio/playback.fifo /run/agent-audio/capture.fifo /run/agent-audio/mic.enabled 2>/dev/null || true
    if [ ! -S "${RUNTIME_USER_DIR}/pulse/native" ]; then
        PA_ARGS=(
            --daemonize=yes
            --disallow-exit=yes
            --exit-idle-time=-1
            --log-level=error
            -n
            -L "module-native-protocol-unix auth-anonymous=1 socket=${RUNTIME_USER_DIR}/pulse/native"
            -L "module-pipe-sink file=/run/agent-audio/playback.fifo sink_name=agent_speaker format=s16le rate=48000 channels=2 use_system_clock_for_timing=yes"
        )
        if [ "${AGENT_MIC:-0}" = "1" ]; then
            PA_ARGS+=(-L "module-pipe-source file=/run/agent-audio/capture.fifo source_name=agent_mic format=s16le rate=48000 channels=1")
        fi
        PA_ARGS+=(-L "module-always-sink")
        pulseaudio "${PA_ARGS[@]}" 2>/dev/null || true
    fi
fi

# 6. Avvio window manager (openbox) in loop persistente dentro il monitor virtuale isolato Xephyr (:99)
#    Così tutte le finestre dentro Xephyr sono ridimensionabili, spostabili, massimizzabili (Alt+F10 / F11)
#    e si adattano dinamicamente quando la finestra Xephyr cambia risoluzione (come un monitor virtuale)
if [ "${AGENT_XEPHYR_ENABLED:-0}" = "1" ] && [ -n "${DISPLAY:-}" ] && command -v openbox >/dev/null 2>&1; then
    cat <<'EOF' > /tmp/openbox-rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
  </focus>
  <placement>
    <policy>Smart</policy>
    <center>yes</center>
  </placement>
  <theme>
    <name>Clearlooks</name>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
  </theme>
  <desktops>
    <number>1</number>
  </desktops>
  <resize>
    <drawContents>yes</drawContents>
  </resize>
  <keyboard>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
    <keybind key="A-F4"><action name="Close"/></keybind>
    <keybind key="A-F10"><action name="ToggleMaximize"/></keybind>
    <keybind key="F11"><action name="ToggleFullscreen"/></keybind>
  </keyboard>
  <mouse>
    <context name="Frame">
      <mousebind button="A-Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
      <mousebind button="A-Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="A-Right" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
      <mousebind button="A-Right" action="Drag"><action name="Resize"/></mousebind>
    </context>
    <context name="Titlebar">
      <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind>
    </context>
    <context name="Top"><mousebind button="Left" action="Drag"><action name="Resize"><edge>top</edge></action></mousebind></context>
    <context name="Left"><mousebind button="Left" action="Drag"><action name="Resize"><edge>left</edge></action></mousebind></context>
    <context name="Right"><mousebind button="Left" action="Drag"><action name="Resize"><edge>right</edge></action></mousebind></context>
    <context name="Bottom"><mousebind button="Left" action="Drag"><action name="Resize"><edge>bottom</edge></action></mousebind></context>
    <context name="TRCorner"><mousebind button="Left" action="Drag"><action name="Resize"/></mousebind></context>
    <context name="TLCorner"><mousebind button="Left" action="Drag"><action name="Resize"/></mousebind></context>
    <context name="BRCorner"><mousebind button="Left" action="Drag"><action name="Resize"/></mousebind></context>
    <context name="BLCorner"><mousebind button="Left" action="Drag"><action name="Resize"/></mousebind></context>
    <context name="Maximize"><mousebind button="Left" action="Click"><action name="ToggleMaximize"/></mousebind></context>
    <context name="Iconify"><mousebind button="Left" action="Click"><action name="Iconify"/></mousebind></context>
    <context name="Close"><mousebind button="Left" action="Click"><action name="Close"/></mousebind></context>
  </mouse>
  <applications>
    <application class="*">
      <decor>yes</decor>
    </application>
  </applications>
</openbox_config>
EOF
    (
        while true; do
            if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] && xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
                xsetroot -display "${DISPLAY}" -solid "#1e1e2e" 2>/dev/null || true
                openbox --config-file /tmp/openbox-rc.xml >/dev/null 2>&1 || true
            fi
            sleep 1
        done
    ) &
fi

exec "$@"
