#!/usr/bin/env bash
set -euo pipefail

APP_NAME="$(basename "$0")"
if [ "${APP_NAME}" = "agent-gui-launcher" ]; then
    APP_NAME="${1:-}"
    shift || true
fi

# Avvia un bus D-Bus di sessione isolato nel container se non già presente
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- "$0" "$@"
fi

# Se il monitor virtuale isolato (Xephyr :99) era stato chiuso dall'utente, lo ricrea automaticamente on-demand
ensure_virtual_display() {
    if [ "${AGENT_XEPHYR_ENABLED:-0}" != "1" ] || [ -z "${DISPLAY:-}" ]; then
        return 0
    fi
    if command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
        return 0
    fi
    if [ -d /run/agent-audio ]; then
        echo "[agent-box] Monitor virtuale (${DISPLAY}) chiuso: riavvio automatico in corso..."
        touch /run/agent-audio/start-xephyr 2>/dev/null || true
        local waited=0
        while [ "${waited}" -lt 30 ]; do
            if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
                # Attende un attimo che openbox/tint2 si riaggancino al nuovo Xephyr
                sleep 0.8
                return 0
            fi
            sleep 0.5
            waited=$((waited + 1))
        done
        echo "[agent-box] ATTENZIONE: il monitor virtuale (${DISPLAY}) non ha risposto entro 15s." >&2
    fi
}
ensure_virtual_display

# Inizializza e sblocca GNOME Keyring (Secret Service API) per Claude Desktop e altre app Electron
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
    mkdir -p "${HOME}/.local/share/keyrings" "${HOME}/.cache"
    chmod 0700 "${HOME}/.local/share/keyrings"
    if [ ! -f "${HOME}/.local/share/keyrings/default" ]; then
        printf 'login' > "${HOME}/.local/share/keyrings/default"
    fi
    if ! pgrep -u "$(id -u)" -x gnome-keyring-daemon >/dev/null 2>&1; then
        eval "$(printf '\n' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null || true)"
        export GNOME_KEYRING_CONTROL
    fi
fi

OZONE_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
COMMON_ELECTRON_FLAGS=(
    "--no-sandbox"
    "--disable-gpu-sandbox"
    "--password-store=gnome-libsecret"
    "--ozone-platform-hint=${OZONE_HINT}"
)

launch_webapp() {
    local profile_name="$1"
    local wm_class="$2"
    local url="$3"
    shift 3
    local profile_dir="${HOME}/.config/agent-gui/${profile_name}"
    mkdir -p "${profile_dir}"

    if command -v google-chrome-stable >/dev/null 2>&1; then
        exec google-chrome-stable \
            "${COMMON_ELECTRON_FLAGS[@]}" \
            --no-first-run \
            --no-default-browser-check \
            --user-data-dir="${profile_dir}" \
            --class="${wm_class}" \
            --app="${url}" \
            "$@"
    elif command -v falkon >/dev/null 2>&1; then
        exec falkon --no-remote -p "${profile_dir}" "${url}" "$@"
    else
        echo "[agent-box] ERRORE: nessun browser GUI (google-chrome-stable / falkon) trovato nel container." >&2
        exit 1
    fi
}

launch_terminal_gui() {
    local title="$1"
    local bin="$2"
    shift 2
    if command -v alacritty >/dev/null 2>&1; then
        exec alacritty -T "${title}" --working-directory "$(pwd)" -e "${bin}" "$@"
    elif command -v xterm >/dev/null 2>&1; then
        exec xterm -T "${title}" -e "${bin}" "$@"
    else
        echo "[agent-box] ATTENZIONE: alacritty/xterm non trovato, avvio ${bin} nel terminale corrente..."
        exec "${bin}" "$@"
    fi
}

case "${APP_NAME}" in
    claude-desktop|claude-gui)
        if [ -x /usr/lib/claude-desktop/claude-desktop ]; then
            exec /usr/lib/claude-desktop/claude-desktop "${COMMON_ELECTRON_FLAGS[@]}" "$@"
        else
            launch_webapp "claude" "ClaudeDesktop" "https://claude.ai" "$@"
        fi
        ;;
    chatgpt-desktop|chatgpt-gui|codex-desktop|codex-gui)
        if [ -x /usr/bin/chatgpt ]; then
            exec /usr/bin/chatgpt "${COMMON_ELECTRON_FLAGS[@]}" "$@"
        else
            launch_webapp "chatgpt" "ChatGPTDesktop" "https://chatgpt.com" "$@"
        fi
        ;;
    opencode-desktop|opencode-gui)
        for oc_bin in \
            /opt/OpenCode/ai.opencode.desktop \
            /opt/OpenCode/opencode-desktop \
            /opt/OpenCode/opencode \
            /usr/bin/ai.opencode.desktop \
            /usr/bin/opencode-desktop; do
            if [ -x "${oc_bin}" ]; then
                exec "${oc_bin}" "${COMMON_ELECTRON_FLAGS[@]}" "$@"
            fi
        done
        export BROWSER="/usr/local/bin/agent-webapp-open"
        exec opencode web "$@"
        ;;
    opencode-web)
        export BROWSER="/usr/local/bin/agent-webapp-open"
        exec opencode web "$@"
        ;;
    aider-desktop|aider-gui)
        export BROWSER="/usr/local/bin/agent-webapp-open"
        exec aider --gui "$@"
        ;;
    grok-desktop|grok-gui)
        if [ "${1:-}" = "--terminal" ]; then
            shift
            launch_terminal_gui "xAI Grok CLI" grok "$@"
        else
            launch_webapp "grok" "GrokDesktop" "https://grok.com" "$@"
        fi
        ;;
    gemini-desktop|gemini-gui)
        if [ "${1:-}" = "--terminal" ]; then
            shift
            launch_terminal_gui "Google Gemini CLI" gemini "$@"
        else
            launch_webapp "gemini" "GeminiDesktop" "https://gemini.google.com" "$@"
        fi
        ;;
    agy-desktop|agy-gui|antigravity-desktop|antigravity-gui)
        if [ "${1:-}" = "--web" ]; then
            shift
            launch_webapp "antigravity" "AntigravityWeb" "https://idx.google.com" "$@"
        else
            launch_terminal_gui "Google Antigravity (agy)" agy "$@"
        fi
        ;;
    pi-desktop|pi-gui)
        launch_terminal_gui "Pi Coding Agent" pi "$@"
        ;;
    hermes-desktop|hermes-gui)
        HERMES_UNPACKED="${HOME}/.hermes/hermes-agent/apps/desktop/release/linux-unpacked"
        find_hermes_electron() {
            for cand in "${HERMES_UNPACKED}/hermes" "${HERMES_UNPACKED}/Hermes" "${HERMES_UNPACKED}/hermes-desktop"; do
                if [ -x "${cand}" ] && [ ! -d "${cand}" ]; then
                    printf '%s' "${cand}"
                    return 0
                fi
            done
            if [ -d "${HERMES_UNPACKED}" ]; then
                find "${HERMES_UNPACKED}" -maxdepth 1 -type f -executable \
                    ! -name 'chrome-sandbox' ! -name 'chrome_crashpad_handler' ! -name '*.so*' \
                    -print -quit 2>/dev/null || true
            fi
        }
        HERMES_BIN="$(find_hermes_electron || true)"
        if [ -z "${HERMES_BIN}" ]; then
            # Compila/aggiorna il pacchetto desktop Electron (nel container rootless il passo finale chown chrome-sandbox fallisce: è atteso)
            AGENT_BOX_HERMES_DIRECT=1 hermes desktop || true
            HERMES_BIN="$(find_hermes_electron || true)"
        fi
        if [ -n "${HERMES_BIN}" ] && [ -x "${HERMES_BIN}" ]; then
            exec "${HERMES_BIN}" "${COMMON_ELECTRON_FLAGS[@]}" "$@"
        fi
        echo "[agent-box] ERRORE: binario Electron di Hermes Desktop non trovato in ${HERMES_UNPACKED}." >&2
        exit 1
        ;;
    agent-webapp-open)
        launch_webapp "webapp" "AgentBoxWebApp" "${1:-http://127.0.0.1:8501}"
        ;;
    *)
        echo "[agent-box] Applicazione GUI sconosciuta: '${APP_NAME}'" >&2
        exit 1
        ;;
esac
