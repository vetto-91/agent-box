#!/bin/sh
set -eu

# umask 0000 garantisce che il socket Unix /run/opensnitch/osui.sock sia
# scrivibile anche da opensnitchd nel container firewall
umask 0000

CONFIG_DIR="/home/snitch/.config/opensnitch"
CONFIG_FILE="${CONFIG_DIR}/settings.conf"
SOCKET_PATH="/run/opensnitch/osui.sock"

mkdir -p "${CONFIG_DIR}"
rm -f "${SOCKET_PATH}" /tmp/osui.sock
ln -sf "${SOCKET_PATH}" /tmp/osui.sock

# Pre-configura (o aggiorna) opensnitch-ui per ascoltare sul socket condiviso col firewall
cat <<EOF > "${CONFIG_FILE}"
[global]
server_address = unix://${SOCKET_PATH}
address = unix://${SOCKET_PATH}
default_timeout = 30
default_action = 1
default_duration = 0
EOF

# Rende il cookie Xauthority indipendente dall'hostname del container (FamilyWild)
if [ -n "${XAUTHORITY:-}" ] && [ -s "${XAUTHORITY}" ] && command -v xauth >/dev/null 2>&1; then
    XAUTH_TMP="/tmp/.Xauthority"
    rm -f "${XAUTH_TMP}"
    xauth -f "${XAUTHORITY}" nlist 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "${XAUTH_TMP}" nmerge - >/dev/null 2>&1 || cp -f "${XAUTHORITY}" "${XAUTH_TMP}" 2>/dev/null || true
    if [ -s "${XAUTH_TMP}" ]; then
        export XAUTHORITY="${XAUTH_TMP}"
    fi
fi

# Rilevamento automatico Wayland vs XWayland/X11 dentro il container
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}" ]; then
    echo "[opensnitch-ui] Socket Wayland rilevato: ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
elif [ -z "${QT_QPA_PLATFORM:-}" ] || [ "${QT_QPA_PLATFORM}" = "wayland;xcb" ]; then
    echo "[opensnitch-ui] Socket Wayland non trovato in ${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY:-}, uso X11/XWayland (xcb) su DISPLAY=${DISPLAY:-:0}"
    export QT_QPA_PLATFORM="xcb"
fi

export QT_X11_NO_MITSHM=1
export QT_XCB_GL_INTEGRATION="${QT_XCB_GL_INTEGRATION:-none}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

echo "[opensnitch-ui] Utente: $(id)"
echo "[opensnitch-ui] QT_QPA_PLATFORM=${QT_QPA_PLATFORM}"
echo "[opensnitch-ui] Finestra principale all'avvio: ${OPENSNITCH_SHOW_MAIN_WINDOW:-1}"

# Bridge audio tramite FIFO PCM unidirezionali (il socket PulseAudio dell'host non viene MAI esposto ad agent)
# Nota di sicurezza: AGENT_MIC viene passato dall'host a opensnitch-ui, quindi l'agente non può auto-abilitare il microfono
if [ "${AGENT_AUDIO:-1}" = "1" ] && [ -d /run/agent-audio ] && command -v pacat >/dev/null 2>&1; then
    # Disabilita SHM tra container e host (evita audio muto tra IPC namespace diversi su PipeWire/PulseAudio)
    cat <<'EOF' > /tmp/pulse-client.conf
enable-shm = no
autospawn = no
EOF
    (
        HOST_PULSE_SOCK="/run/user/$(id -u)/pulse/native"
        export PULSE_SERVER="unix:${HOST_PULSE_SOCK}"
        export PULSE_CLIENTCONFIG="/tmp/pulse-client.conf"
        export XDG_CONFIG_HOME="/tmp"
        if [ -r /tmp/.pulse-cookie ]; then
            export PULSE_COOKIE="/tmp/.pulse-cookie"
        fi
        while true; do
            if [ -p /run/agent-audio/playback.fifo ] && [ -S "${HOST_PULSE_SOCK}" ]; then
                echo "[opensnitch-ui] Audio bridge playback attivo -> ${HOST_PULSE_SOCK}"
                pacat --playback --raw --format=s16le --rate=48000 --channels=2 --latency-msec=40 \
                    --property=application.name=agent-box < /run/agent-audio/playback.fifo || true
                sleep 1
            else
                sleep 1
            fi
        done
    ) &
    if [ "${AGENT_MIC:-0}" = "1" ]; then
        (
            HOST_PULSE_SOCK="/run/user/$(id -u)/pulse/native"
            export PULSE_SERVER="unix:${HOST_PULSE_SOCK}"
            export PULSE_CLIENTCONFIG="/tmp/pulse-client.conf"
            export XDG_CONFIG_HOME="/tmp"
            if [ -r /tmp/.pulse-cookie ]; then
                export PULSE_COOKIE="/tmp/.pulse-cookie"
            fi
            while true; do
                if [ -p /run/agent-audio/capture.fifo ] && [ -S "${HOST_PULSE_SOCK}" ]; then
                    echo "[opensnitch-ui] Audio bridge microfono attivo <- ${HOST_PULSE_SOCK}"
                    pacat --record --raw --format=s16le --rate=48000 --channels=1 --latency-msec=40 \
                        --property=application.name=agent-box-mic > /run/agent-audio/capture.fifo || true
                    sleep 1
                else
                    sleep 1
                fi
            done
        ) &
    fi
fi

# Server X11 annidato e isolato (Xephyr :99) per il container agent:
# - Impedisce agli agenti di fare screenshot degli schermi host, keylogging o cliccare sui popup OpenSnitch
# - Permette ad agent di usare xdotool (mouse/tastiera) e xrandr dentro il monitor virtuale :99
if [ "${AGENT_XEPHYR_ENABLED:-0}" = "1" ] && command -v Xephyr >/dev/null 2>&1; then
    XEPHYR_DISPLAY="${AGENT_XEPHYR_DISPLAY:-:99}"
    XEPHYR_SCREEN="${AGENT_SCREEN_SIZE:-1600x900}"
    XEPHYR_FS="${AGENT_FULLSCREEN:-0}"
    echo "[opensnitch-ui] Avvio monitor virtuale isolato Xephyr ${XEPHYR_DISPLAY} (${XEPHYR_SCREEN}, fullscreen=${XEPHYR_FS})..."
    rm -f "/tmp/.X11-unix/X${XEPHYR_DISPLAY#:}" "/tmp/.X${XEPHYR_DISPLAY#:}-lock" 2>/dev/null || true
    (
        while true; do
            if [ "${XEPHYR_FS}" = "1" ]; then
                Xephyr "${XEPHYR_DISPLAY}" \
                    -fullscreen \
                    -host-cursor \
                    -ac \
                    -nolisten tcp \
                    +extension RANDR \
                    +extension GLX \
                    +extension RENDER \
                    -title "Agent-Box Virtual Monitor (${XEPHYR_DISPLAY})" \
                    2>&1 || true
            else
                Xephyr "${XEPHYR_DISPLAY}" \
                    -screen "${XEPHYR_SCREEN}" \
                    -resizeable \
                    -host-cursor \
                    -ac \
                    -nolisten tcp \
                    +extension RANDR \
                    +extension GLX \
                    +extension RENDER \
                    -title "Agent-Box Virtual Monitor (${XEPHYR_DISPLAY})" \
                    2>&1 || true
            fi
            sleep 2
        done
    ) &
fi

echo "[opensnitch-ui] Avvio interfaccia grafica su socket unix://${SOCKET_PATH} ..."

exec /usr/bin/python3 /usr/local/bin/opensnitch-launcher.py --socket "unix://${SOCKET_PATH}"
