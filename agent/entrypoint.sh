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
    "${HOME}/.cache/tmp" \
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

# 2b. Migrazione automatica vecchia installazione uv di Hermes (priva di apps/desktop)
#     Se ~/.local/bin/hermes punta a uv/tools/hermes-agent e manca ~/.hermes/hermes-agent,
#     rimuove il vecchio shim così il wrapper /usr/local/bin/hermes usa l'installer ufficiale curl (--include-desktop).
if [ -e "${HOME}/.local/bin/hermes" ] && [ ! -d "${HOME}/.hermes/hermes-agent" ]; then
    if grep -q "uv/tools/hermes-agent" "${HOME}/.local/bin/hermes" 2>/dev/null || \
       readlink -f "${HOME}/.local/bin/hermes" 2>/dev/null | grep -q "uv/tools/hermes-agent"; then
        rm -f "${HOME}/.local/bin/hermes"
        echo "[agent-box] Rimosso vecchio shim uv di Hermes (~/.local/bin/hermes): al prossimo 'hermes' verrà installata la versione ufficiale completa (--include-desktop)."
    fi
fi

# 2c. Rimuove eventuali binari GUI estratti nel sysroot che scavalcherebbero /usr/local/bin/* (--no-sandbox)
#     (agent-gui-launcher usa comunque i binari aggiornati dentro ~/.local/sysroot/usr/lib/... con --no-sandbox)
rm -f \
    "${HOME}/.local/sysroot/usr/bin/claude-desktop" \
    "${HOME}/.local/sysroot/usr/bin/chatgpt" \
    "${HOME}/.local/sysroot/usr/bin/opencode-desktop" \
    "${HOME}/.local/sysroot/usr/bin/ai.opencode" \
    "${HOME}/.local/sysroot/usr/bin/ai.opencode.desktop" 2>/dev/null || true

# 3. Configura prompt sandbox, TMPDIR/BUN_TMPDIR eseguibile (per opencode/opencode2/claude) e supporto TLS in .bashrc
if [ ! -f "${HOME}/.bashrc" ] || ! grep -q "AGENT-BOX" "${HOME}/.bashrc" 2>/dev/null; then
    cat <<'EOF' >> "${HOME}/.bashrc"

# --- AGENT-BOX SANDBOX PROMPT ---
export PS1='\[\033[1;31m\][🔒 agent-box]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\]\$ '
alias ll='ls -la --color=auto'
EOF
fi
if ! grep -q "BUN_TMPDIR" "${HOME}/.bashrc" 2>/dev/null; then
    cat <<'EOF' >> "${HOME}/.bashrc"
export TMPDIR="${HOME}/.cache/tmp"
export BUN_TMPDIR="${HOME}/.cache/tmp"
[ "${AGENT_XEPHYR_ENABLED:-0}" = "1" ] && export XLIB_SKIP_ARGB_VISUALS=1
EOF
fi

# 4. Configurazione automatica modelli locali (OpenCode, Pi Agent, Codex)
LOCAL_URL="${LOCAL_LLM_BASE_URL:-}"
LOCAL_KEY="${LOCAL_LLM_API_KEY:-local}"
LOCAL_MODEL="${LOCAL_LLM_MODEL:-qwen2.5-coder:latest}"
LOCAL_NAME="${LOCAL_LLM_NAME:-Local LLM}"

# 4a. OpenCode (~/.config/opencode/opencode.json)
#     Crea il file se manca (o se AGENT_REGENERATE_LOCAL_CONFIG=1), altrimenti sincronizza
#     in modo non distruttivo i soli baseURL dei provider ollama/ollama-* da .env preservando modelli e altri provider.
if [ -n "${OLLAMA_HOST:-}" ] || [ -n "${OLLAMA_HOSTS:-}" ] || [ -n "${LOCAL_URL}" ]; then
    OPENCODE_CFG="${HOME}/.config/opencode/opencode.json"
    if [ ! -f "${OPENCODE_CFG}" ] || [ "${AGENT_REGENERATE_LOCAL_CONFIG:-0}" = "1" ]; then
        jq -n \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg ollama_hosts "${OLLAMA_HOSTS:-}" \
            --arg local_url "${LOCAL_URL}" \
            --arg local_key "${LOCAL_KEY}" \
            --arg local_model "${LOCAL_MODEL}" \
            --arg local_name "${LOCAL_NAME}" '
            def clean_url: gsub("^\\s+|\\s+$"; "") | sub("/+$"; "");
            def extra_list:
                ($ollama_hosts | gsub(";"; ",") | split(",") | map(clean_url) | map(select(length > 0)))
                | map(select(. != ($ollama_url | clean_url)));
            {"$schema": "https://opencode.ai/config.json", "provider": {}}
            | if ($ollama_url | clean_url) != "" then
                .provider.ollama = {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Ollama (Local)",
                    "options": {"baseURL": (($ollama_url | clean_url) + "/v1")},
                    "models": {}
                }
              else . end
            | reduce (extra_list | to_entries[]) as $item (.;
                .provider["ollama-\($item.key + 2)"] = {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Ollama #\($item.key + 2) (\($item.value))",
                    "options": {"baseURL": ($item.value + "/v1")},
                    "models": {}
                }
              )
            | if $local_url != "" then
                .provider.local = {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": $local_name,
                    "options": {"baseURL": $local_url, "apiKey": $local_key},
                    "models": { ($local_model): {"name": $local_model} }
                }
              else . end
        ' > "${OPENCODE_CFG}"
    elif [ -n "${OLLAMA_HOST:-}" ] || [ -n "${OLLAMA_HOSTS:-}" ]; then
        jq \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg ollama_hosts "${OLLAMA_HOSTS:-}" '
            def clean_url: gsub("^\\s+|\\s+$"; "") | sub("/+$"; "");
            def extra_list:
                ($ollama_hosts | gsub(";"; ",") | split(",") | map(clean_url) | map(select(length > 0)))
                | map(select(. != ($ollama_url | clean_url)));
            .provider = (.provider // {})
            | if ($ollama_url | clean_url) != "" then
                .provider.ollama = ((.provider.ollama // {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Ollama (Local)",
                    "models": {}
                }) | .options = ((.options // {}) + {"baseURL": (($ollama_url | clean_url) + "/v1")}))
              else . end
            | reduce (extra_list | to_entries[]) as $item (.;
                .provider["ollama-\($item.key + 2)"] = ((.provider["ollama-\($item.key + 2)"] // {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Ollama #\($item.key + 2) (\($item.value))",
                    "models": {}
                }) | .options = ((.options // {}) + {"baseURL": ($item.value + "/v1")}))
              )
        ' "${OPENCODE_CFG}" > "${OPENCODE_CFG}.tmp" 2>/dev/null && mv -f "${OPENCODE_CFG}.tmp" "${OPENCODE_CFG}" || rm -f "${OPENCODE_CFG}.tmp"
    fi
fi

# 4b. Pi Agent (~/.pi/agent/models.json)
#     Sincronizza in modo non distruttivo i baseUrl di ollama/ollama-* da .env preservando i modelli configurati dall'utente (es. gemma4:e4b)
if [ -n "${OLLAMA_HOST:-}" ] || [ -n "${OLLAMA_HOSTS:-}" ] || [ -n "${LOCAL_URL}" ]; then
    PI_MODELS="${HOME}/.pi/agent/models.json"
    if [ ! -f "${PI_MODELS}" ] || [ "${AGENT_REGENERATE_LOCAL_CONFIG:-0}" = "1" ]; then
        jq -n \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg ollama_hosts "${OLLAMA_HOSTS:-}" \
            --arg local_url "${LOCAL_URL}" \
            --arg local_key "${LOCAL_KEY}" \
            --arg local_model "${LOCAL_MODEL}" '
            def clean_url: gsub("^\\s+|\\s+$"; "") | sub("/+$"; "");
            def extra_list:
                ($ollama_hosts | gsub(";"; ",") | split(",") | map(clean_url) | map(select(length > 0)))
                | map(select(. != ($ollama_url | clean_url)));
            {"providers": {}}
            | if ($ollama_url | clean_url) != "" then
                .providers.ollama = {
                    "baseUrl": (($ollama_url | clean_url) + "/v1"),
                    "api": "openai-completions",
                    "apiKey": "ollama",
                    "models": [{"id": $local_model}]
                }
              else . end
            | reduce (extra_list | to_entries[]) as $item (.;
                .providers["ollama-\($item.key + 2)"] = {
                    "baseUrl": ($item.value + "/v1"),
                    "api": "openai-completions",
                    "apiKey": "ollama",
                    "models": [{"id": $local_model}]
                }
              )
            | if $local_url != "" then
                .providers.local = {
                    "baseUrl": $local_url,
                    "api": "openai-completions",
                    "apiKey": $local_key,
                    "models": [{"id": $local_model}]
                }
              else . end
        ' > "${PI_MODELS}"
    elif [ -n "${OLLAMA_HOST:-}" ] || [ -n "${OLLAMA_HOSTS:-}" ]; then
        jq \
            --arg ollama_url "${OLLAMA_HOST:-}" \
            --arg ollama_hosts "${OLLAMA_HOSTS:-}" \
            --arg local_model "${LOCAL_MODEL}" '
            def clean_url: gsub("^\\s+|\\s+$"; "") | sub("/+$"; "");
            def extra_list:
                ($ollama_hosts | gsub(";"; ",") | split(",") | map(clean_url) | map(select(length > 0)))
                | map(select(. != ($ollama_url | clean_url)));
            .providers = (.providers // {})
            | if ($ollama_url | clean_url) != "" then
                .providers.ollama = ((.providers.ollama // {
                    "api": "openai-completions",
                    "apiKey": "ollama",
                    "models": [{"id": $local_model}]
                }) + {"baseUrl": (($ollama_url | clean_url) + "/v1")})
              else . end
            | reduce (extra_list | to_entries[]) as $item (.;
                .providers["ollama-\($item.key + 2)"] = ((.providers["ollama-\($item.key + 2)"] // {
                    "api": "openai-completions",
                    "apiKey": "ollama",
                    "models": [{"id": $local_model}]
                }) + {"baseUrl": ($item.value + "/v1")})
              )
        ' "${PI_MODELS}" > "${PI_MODELS}.tmp" 2>/dev/null && mv -f "${PI_MODELS}.tmp" "${PI_MODELS}" || rm -f "${PI_MODELS}.tmp"
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
    # Non rimuovere playback.fifo/capture.fifo se esistono già come FIFO: mantiene lo stesso inode condiviso con opensnitch-ui!
    [ -p /run/agent-audio/playback.fifo ] || { rm -f /run/agent-audio/playback.fifo 2>/dev/null || true; mkfifo /run/agent-audio/playback.fifo 2>/dev/null || true; }
    if [ "${AGENT_MIC:-0}" = "1" ]; then
        [ -p /run/agent-audio/capture.fifo ] || { rm -f /run/agent-audio/capture.fifo 2>/dev/null || true; mkfifo /run/agent-audio/capture.fifo 2>/dev/null || true; }
    fi
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
    <drawContents>no</drawContents>
  </resize>
  <keyboard>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
    <keybind key="A-F4"><action name="Close"/></keybind>
    <keybind key="A-F10"><action name="ToggleMaximize"/></keybind>
    <keybind key="F11"><action name="Execute"><command>sh -c 'touch /run/agent-audio/toggle-fullscreen'</command></action></keybind>
    <keybind key="A-F11"><action name="ToggleFullscreen"/></keybind>
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
    # Barra delle applicazioni (tint2) in basso per recuperare le finestre ridotte a icona (_)
    if command -v tint2 >/dev/null 2>&1; then
        cat <<'EOF' > /tmp/tint2rc
#-------------------------------------
# Backgrounds
rounded = 0
border_width = 0
background_color = #181825 95
border_color = #313244 100

rounded = 4
border_width = 1
background_color = #313244 100
border_color = #585b70 100

rounded = 4
border_width = 1
background_color = #45475a 100
border_color = #89b4fa 100

rounded = 4
border_width = 1
background_color = #1e1e2e 85
border_color = #45475a 80

#-------------------------------------
# Panel
panel_items = TC
panel_size = 100% 34
panel_margin = 0 0
panel_padding = 6 3 6
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
strut_policy = follow_size

#-------------------------------------
# Taskbar
taskbar_mode = single_desktop
taskbar_padding = 4 0 4
taskbar_background_id = 0
taskbar_active_background_id = 0
task_icon = 1
task_text = 1
task_centered = 0
task_maximum_size = 240 28
task_padding = 8 4 6
task_font = Sans 10
task_font_color = #cdd6f4 100
task_active_font_color = #ffffff 100
task_iconified_font_color = #a6adc8 90
task_background_id = 2
task_active_background_id = 3
task_iconified_background_id = 4
mouse_left = toggle_iconify
mouse_middle = close
mouse_right = maximize_restore

#-------------------------------------
# Clock
time1_format = %H:%M
time1_font = Sans Bold 10
clock_font_color = #cdd6f4 100
clock_padding = 8 0
clock_background_id = 0
EOF
        (
            while true; do
                if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] && xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
                    tint2 -c /tmp/tint2rc >/dev/null 2>&1 || true
                fi
                sleep 1
            done
        ) &
    fi
    # Watcher RandR: quando ridimensioni o massimizzi la finestra Xephyr sull'host,
    # aggiorna automaticamente la risoluzione del monitor virtuale :99 per tutte le app al suo interno
    if command -v xrandr >/dev/null 2>&1; then
        (
            LAST_PREF=""
            while true; do
                if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
                    OUT_INFO="$(xrandr -display "${DISPLAY}" --query 2>/dev/null || true)"
                    # Estrae la modalità preferita (+) e quella corrente (*)
                    PREF_MODE="$(printf '%s\n' "${OUT_INFO}" | awk '/\+/{print $1; exit}')"
                    CURR_MODE="$(printf '%s\n' "${OUT_INFO}" | awk '/\*/{print $1; exit}')"
                    if [ -n "${PREF_MODE}" ] && [ "${PREF_MODE}" != "${CURR_MODE}" ] && [ "${PREF_MODE}" != "${LAST_PREF}" ]; then
                        xrandr -display "${DISPLAY}" --auto 2>/dev/null || true
                        LAST_PREF="${PREF_MODE}"
                    fi
                fi
                sleep 1
            done
        ) &
    fi
fi

exec "$@"
