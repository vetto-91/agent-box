#!/usr/bin/env bash
set -euo pipefail

TOOL="$(basename "$0")"
mkdir -p "${HOME}/.cache/tmp" "${HOME}/.local/bin"

# Bun / OpenCode / Claude Code estraggono librerie/binari in TMPDIR: usa ~/.cache/tmp (eseguibile) invece di /tmp (noexec)
export TMPDIR="${HOME}/.cache/tmp"
export BUN_TMPDIR="${HOME}/.cache/tmp"

find_pi_bin() {
    for candidate in \
        "${HOME}/.local/bin/pi" \
        "${HOME}/.npm-global/bin/pi" \
        "${HOME}/.pi/bin/pi" \
        "${HOME}/.pi/agent/bin/pi"; do
        if [ -x "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

case "${TOOL}" in
    claude)
        BIN="${HOME}/.local/bin/claude"
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] Installazione Claude Code (Native Installer ufficiale: https://claude.ai/install.sh) in ${HOME}/.local/bin ..."
            curl -fSL --connect-timeout 15 https://claude.ai/install.sh | bash
        fi
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] ERRORE: eseguibile 'claude' non trovato in ${BIN} dopo l'installazione." >&2
            exit 1
        fi
        exec "${BIN}" "$@"
        ;;
    opencode)
        BIN="${HOME}/.opencode/bin/opencode"
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] Installazione OpenCode v2 dal sito ufficiale (https://opencode.ai/v2/install) in ${HOME}/.opencode ..."
            echo "[agent-box] (Download da opencode.ai e registry.npmjs.org: se appare un popup OpenSnitch, approvalo per continuare)"
            OC_INSTALLER="${HOME}/.cache/tmp/opencode-v2-install.$$.sh"
            curl -fSL --connect-timeout 15 -o "${OC_INSTALLER}" https://opencode.ai/v2/install
            bash "${OC_INSTALLER}" --no-modify-path
            rm -f "${OC_INSTALLER}"
        fi
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] ERRORE: eseguibile 'opencode' non trovato in ${BIN} dopo l'installazione." >&2
            exit 1
        fi
        exec "${BIN}" "$@"
        ;;
    pi)
        BIN="$(find_pi_bin || true)"
        if [ -z "${BIN}" ]; then
            echo "[agent-box] Installazione Pi Coding Agent dal sito ufficiale (https://pi.dev/install.sh) in ${HOME} ..."
            # Nasconde /usr/local/bin/pi (questo wrapper) dal PATH durante l'installazione,
            # altrimenti pi.dev/install.sh rileva /usr/local/bin/pi come installazione esistente e rifiuta di procedere.
            CLEAN_BIN="${HOME}/.cache/tmp/pi-install-bin.$$"
            mkdir -p "${CLEAN_BIN}"
            for f in /usr/local/bin/*; do
                [ -e "$f" ] || continue
                base="$(basename "$f")"
                [ "${base}" = "pi" ] && continue
                ln -sf "$f" "${CLEAN_BIN}/${base}"
            done
            CLEAN_PATH="$(printf '%s' "${PATH}" | sed "s|/usr/local/bin|${CLEAN_BIN}|g")"
            PATH="${CLEAN_PATH}" curl -fSL --connect-timeout 15 https://pi.dev/install.sh | PATH="${CLEAN_PATH}" sh
            rm -rf "${CLEAN_BIN}"
            BIN="$(find_pi_bin || true)"
        fi
        if [ -z "${BIN}" ]; then
            echo "[agent-box] ERRORE: eseguibile 'pi' non trovato dopo l'installazione." >&2
            exit 1
        fi
        exec "${BIN}" "$@"
        ;;
    hermes)
        BIN="${HOME}/.local/bin/hermes"
        # Se era presente solo la vecchia installazione uv senza sorgenti desktop (~/.hermes/hermes-agent), usa l'installer ufficiale curl
        if [ ! -x "${BIN}" ] || [ ! -d "${HOME}/.hermes/hermes-agent" ]; then
            echo "[agent-box] Installazione Hermes Agent dal sito ufficiale (NousResearch/hermes-agent install.sh --include-desktop)..."
            curl -fSL --connect-timeout 15 https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --include-desktop
        fi
        if [ -x "${HOME}/.hermes/bin/hermes" ]; then
            BIN="${HOME}/.hermes/bin/hermes"
        fi
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] ERRORE: eseguibile 'hermes' non trovato dopo l'installazione." >&2
            exit 1
        fi
        # In container rootless (cap_drop: ALL), "hermes desktop" fallisce sul sudo chown di chrome-sandbox:
        # delega al launcher GUI isolato che avvia Electron con --no-sandbox.
        if [ "${1:-}" = "desktop" ] && [ "${AGENT_BOX_HERMES_DIRECT:-0}" != "1" ]; then
            shift
            exec /usr/local/bin/agent-gui-launcher hermes-desktop "$@"
        fi
        exec "${BIN}" "$@"
        ;;
    *)
        echo "[agent-box] Tool sconosciuto: ${TOOL}" >&2
        exit 1
        ;;
esac
