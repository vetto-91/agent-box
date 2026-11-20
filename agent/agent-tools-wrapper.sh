#!/usr/bin/env bash
set -euo pipefail

TOOL="$(basename "$0")"
mkdir -p "${HOME}/.cache/tmp" "${HOME}/.local/bin"

# Bun / OpenCode estraggono librerie native .so in TMPDIR: usa ~/.cache/tmp (eseguibile) invece di /tmp (noexec)
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
    opencode)
        BIN="${HOME}/.opencode/bin/opencode"
        if [ ! -x "${BIN}" ]; then
            echo "[agent-box] Installazione OpenCode dal sito ufficiale (https://opencode.ai/install) in ${HOME}/.opencode ..."
            curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
        fi
        exec "${BIN}" "$@"
        ;;
    pi)
        BIN="$(find_pi_bin || true)"
        if [ -z "${BIN}" ]; then
            echo "[agent-box] Installazione Pi Coding Agent dal sito ufficiale (https://pi.dev/install.sh) in ${HOME} ..."
            curl -fsSL https://pi.dev/install.sh | sh
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
            curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --include-desktop
        fi
        if [ -x "${HOME}/.hermes/bin/hermes" ]; then
            BIN="${HOME}/.hermes/bin/hermes"
        fi
        exec "${BIN}" "$@"
        ;;
    *)
        echo "[agent-box] Tool sconosciuto: ${TOOL}" >&2
        exit 1
        ;;
esac
