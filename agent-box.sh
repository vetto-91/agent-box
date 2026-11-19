#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_OVERRIDE_FILE="${RUNTIME_DIR}/docker-compose.override.yml"

# Opzioni CLI (valorizzate prima del sottocomando)
CLI_EXTRA_VOLUMES=()
CLI_CPUS=""
CLI_GPU=""
CLI_DISPLAY_MODE=""
CLI_AUDIO=""
CLI_MIC=""
CLI_FW_PROFILE=""

print_usage() {
    cat <<EOF
Utilizzo: $0 [OPZIONI] <COMANDO> [cartella_progetto] [argomenti...]

Comandi CLI:
  build, shell, exec, apt, fw-profile, test-popup, test-isolation, logs, stop
  claude, chatgpt (codex), grok, agy, pi, gemini, opencode, aider, hermes

Comandi GUI / Desktop:
  claude-desktop (claude-gui), chatgpt-desktop (chatgpt-gui / codex-desktop / codex-gui),
  opencode-desktop (opencode-gui / opencode-web), aider-desktop (aider-gui),
  grok-desktop (grok-gui), gemini-desktop (gemini-gui),
  agy-desktop (agy-gui / antigravity-desktop), pi-desktop (pi-gui), hermes-desktop (hermes-gui)

Opzioni:
  -v, --volume HOST:CONTAINER[:ro|rw]   Monta un volume extra del progetto sul disco (ripetibile)
  --cpus <N|all>                        Numero di core CPU per l'agente (default: tutti)
  --gpu <auto|all|igpu|nvidia|none>     Accesso iGPU/GPU (default: auto)
  --display <auto|wayland|xwayland|x11|none>
                                        Modalità finestra grafica per agenti e app (default: auto)
  --no-gui                              Equivale a --display none
  --audio <on|off|1|0>                  Abilita/disabilita uscita audio (default: on)
  --no-audio                            Disabilita completamente audio e microfono
  --mic [on|off|1|0]                    Abilita il microfono nel container (default: disabilitato)
  --no-mic                              Forza il microfono disabilitato (default)
  --fw-profile <profilo>                Importa/attiva un profilo regole OpenSnitch da ./opensnitch-profiles:
                                          interattivo | disabilitato | solo-lan | solo-lan-ia |
                                          solo-internet | solo-provider-ia | solo-443-ipv4
  -h, --help                            Mostra questo messaggio
EOF
}

resolve_opensnitch_profile() {
    local req="$1"
    case "${req}" in
        0|interattivo|interactive|default|0-interattivo-default)
            printf '0-interattivo-default'
            ;;
        1|disabilitato|disabled|allow-all|1-disabilitato-allow-all)
            printf '1-disabilitato-allow-all'
            ;;
        2|solo-lan|lan|lan-only|2-solo-lan)
            printf '2-solo-lan'
            ;;
        3|solo-lan-ia|lan-ia|lan-ai|solo-lan-con-provider-ia|3-solo-lan-con-provider-ia)
            printf '3-solo-lan-con-provider-ia'
            ;;
        4|solo-internet|internet-no-lan|no-lan|4-solo-internet-no-lan)
            printf '4-solo-internet-no-lan'
            ;;
        5|solo-ia|solo-provider-ia|ai-only|ia|5-solo-provider-ia)
            printf '5-solo-provider-ia'
            ;;
        6|solo-443-ipv4|443-ipv4|443|only-443-ipv4|6-solo-443-ipv4)
            printf '6-solo-443-ipv4'
            ;;
        *)
            if [ -d "${SCRIPT_DIR}/opensnitch-profiles/${req}" ]; then
                printf '%s' "${req}"
            else
                return 1
            fi
            ;;
    esac
}

apply_opensnitch_profile() {
    local req="$1"
    local resolved
    if ! resolved="$(resolve_opensnitch_profile "${req}")"; then
        echo "[agent-box] ERRORE: profilo OpenSnitch '${req}' non trovato in ${SCRIPT_DIR}/opensnitch-profiles." >&2
        echo "[agent-box] Profili disponibili:" >&2
        ls -1 "${SCRIPT_DIR}/opensnitch-profiles" >&2
        exit 1
    fi
    mkdir -p "${SCRIPT_DIR}/opensnitch/rules"
    rm -f "${SCRIPT_DIR}/opensnitch/rules/"*.json
    cp -f "${SCRIPT_DIR}/opensnitch-profiles/${resolved}/"*.json "${SCRIPT_DIR}/opensnitch/rules/"
    echo "[agent-box] Profilo OpenSnitch attivato: ${resolved} ($(ls -1 "${SCRIPT_DIR}/opensnitch/rules/"*.json 2>/dev/null | wc -l) regole)"
}

dc() {
    if [ -f "${RUNTIME_OVERRIDE_FILE}" ]; then
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" -f "${RUNTIME_OVERRIDE_FILE}" "$@"
    else
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" "$@"
    fi
}

# Legge una variabile da un file .env senza espandere comandi arbitrari
read_env_var() {
    local file="$1"
    local key="$2"
    local val=""
    if [ -f "${file}" ]; then
        val="$(grep -E "^[[:space:]]*${key}=" "${file}" | tail -n1 | cut -d= -f2- || true)"
        # Rimuove eventuali spazi iniziali/finali e apici esterni
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
    fi
    printf '%s' "${val}"
}

# ==============================================================================
# 1. RILEVAMENTO AUTOMATICO UTENTE CORRENTE E SESSIONE WAYLAND / X11
# ==============================================================================
detect_user_and_display() {
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_UID:-}" ]; then
        # Se lanciato con sudo, usa comunque l'utente desktop reale (non root!)
        export PUID="${SUDO_UID}"
        export PGID="${SUDO_GID:-$(id -g "${SUDO_USER}")}"
        export HOST_USER="${SUDO_USER}"
    else
        export PUID="$(id -u)"
        export PGID="$(id -g)"
        export HOST_USER="$(id -un)"
    fi

    export HOST_HOME="$(getent passwd "${HOST_USER}" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/home/${HOST_USER}}")"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${PUID}}"

    # Verifica che Docker sia raggiungibile e controlla eventuale modalità rootless
    if ! docker info >/dev/null 2>&1; then
        echo "[agent-box] ERRORE: impossibile comunicare con il demone Docker."
        echo "[agent-box] Verifica che Docker sia avviato e che l'utente ${HOST_USER} appartenga al gruppo 'docker'."
        exit 1
    fi
    if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'rootless'; then
        echo "[agent-box] ATTENZIONE: Docker Rootless rilevato. I bind-mount di ${XDG_RUNTIME_DIR} potrebbero avere permessi incompatibili."
    fi

    # Auto-rileva socket Wayland in /run/user/<UID>/wayland-* se non esportato
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
        for wsock in "${XDG_RUNTIME_DIR}"/wayland-[0-9]*; do
            if [ -S "${wsock}" ]; then
                export WAYLAND_DISPLAY="$(basename "${wsock}")"
                break
            fi
        done
    fi

    # Auto-rileva socket X11/XWayland in /tmp/.X11-unix/X* se DISPLAY non è impostato
    if [ -z "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
        for xsock in /tmp/.X11-unix/X*; do
            if [ -S "${xsock}" ]; then
                local xnum="${xsock#/tmp/.X11-unix/X}"
                export DISPLAY=":${xnum}"
                break
            fi
        done
    fi
    export DISPLAY="${DISPLAY:-:0}"

    # Seleziona automaticamente il backend grafico Qt5 (Wayland nativo con fallback XWayland)
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        export XDG_SESSION_TYPE="wayland"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
    else
        export XDG_SESSION_TYPE="x11"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
    fi

    # Prepara le cartelle persistenti (tutte dentro la cartella del progetto) e la directory del socket condiviso
    mkdir -p \
        "${SCRIPT_DIR}/workspace" \
        "${SCRIPT_DIR}/agent-home" \
        "${SCRIPT_DIR}/ollama-data" \
        "${SCRIPT_DIR}/certs" \
        "${SCRIPT_DIR}/opensnitch/rules" \
        "${SCRIPT_DIR}/opensnitch/ui-config" \
        "${SCRIPT_DIR}/opensnitch/socket" \
        "${RUNTIME_DIR}" \
        "${RUNTIME_DIR}/audio" \
        "${RUNTIME_DIR}/x11-isolated"
    chmod 0777 "${SCRIPT_DIR}/opensnitch/socket" 2>/dev/null || true
    chmod 1777 "${RUNTIME_DIR}/x11-isolated" 2>/dev/null || true

    # Inizializza ./hosts modificabile se non esiste ancora
    if [ ! -f "${SCRIPT_DIR}/hosts" ]; then
        cat <<'EOF' > "${SCRIPT_DIR}/hosts"
127.0.0.1 localhost agent-box
::1 localhost ip6-localhost ip6-loopback
EOF
    fi

    # Ripara automaticamente eventuali file/cartelle creati con UID/GID diverso (es. root o 1000 da docker compose diretto)
    local need_chown=0
    if [ ! -w "${SCRIPT_DIR}/agent-home" ] || \
       [ -n "$(find "${SCRIPT_DIR}/agent-home" "${SCRIPT_DIR}/opensnitch/ui-config" "${RUNTIME_DIR}" \( -not -uid "${PUID}" -o -not -gid "${PGID}" \) -print -quit 2>/dev/null || true)" ]; then
        need_chown=1
    fi
    if [ "${need_chown}" -eq 1 ]; then
        echo "[agent-box] Allineamento permessi cartelle locali a ${HOST_USER} (${PUID}:${PGID})..."
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            chown -R "${PUID}:${PGID}" \
                "${SCRIPT_DIR}/agent-home" \
                "${SCRIPT_DIR}/opensnitch/ui-config" \
                "${SCRIPT_DIR}/opensnitch/socket" \
                "${RUNTIME_DIR}" \
                "${SCRIPT_DIR}/hosts" 2>/dev/null || true
            chmod 0777 "${SCRIPT_DIR}/opensnitch/socket" 2>/dev/null || true
        else
            local helper_img=""
            for candidate_img in agent-box-firewall:local agent-box-ui:local ubuntu:26.04; do
                if docker image inspect "${candidate_img}" >/dev/null 2>&1; then
                    helper_img="${candidate_img}"
                    break
                fi
            done
            if [ -n "${helper_img}" ]; then
                docker run --rm -u 0:0 \
                    -v "${SCRIPT_DIR}:/fix" \
                    --entrypoint /bin/sh "${helper_img}" -c \
                    "chown -R ${PUID}:${PGID} /fix/agent-home /fix/opensnitch/ui-config /fix/opensnitch/socket /fix/.runtime /fix/hosts 2>/dev/null || true; chmod 0777 /fix/opensnitch/socket 2>/dev/null || true"
            fi
        fi
    fi

    # Sincronizza PUID e PGID in .env (ignorato da git) così anche i comandi 'docker compose' diretti usano l'UID/GID corretto
    if [ ! -f "${SCRIPT_DIR}/.env" ] && [ -f "${SCRIPT_DIR}/.env.example" ]; then
        cp "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env"
    fi
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        if grep -qE '^PUID=' "${SCRIPT_DIR}/.env"; then
            sed -i "s/^PUID=.*/PUID=${PUID}/" "${SCRIPT_DIR}/.env"
        else
            printf '\nPUID=%s\n' "${PUID}" >> "${SCRIPT_DIR}/.env"
        fi
        if grep -qE '^PGID=' "${SCRIPT_DIR}/.env"; then
            sed -i "s/^PGID=.*/PGID=${PGID}/" "${SCRIPT_DIR}/.env"
        else
            printf 'PGID=%s\n' "${PGID}" >> "${SCRIPT_DIR}/.env"
        fi
    fi

    # Copia il cookie Xauthority attivo (XWayland / X11) dentro opensnitch/socket/.Xauthority
    # e una copia isolata in .runtime/.Xauthority per il container agent
    local xauth_src=""
    if [ -n "${XAUTHORITY:-}" ] && [ -r "${XAUTHORITY}" ]; then
        xauth_src="${XAUTHORITY}"
    else
        for candidate in \
            "${XDG_RUNTIME_DIR}"/.mutter-Xwaylandauth.* \
            "${XDG_RUNTIME_DIR}"/xauth_* \
            "${XDG_RUNTIME_DIR}"/.Xauthority \
            /tmp/xauth_* \
            "${HOST_HOME}/.Xauthority"; do
            if [ -r "${candidate}" ]; then
                xauth_src="${candidate}"
                break
            fi
        done
    fi

    if [ -n "${xauth_src}" ]; then
        cp -f "${xauth_src}" "${SCRIPT_DIR}/opensnitch/socket/.Xauthority" 2>/dev/null || true
        chmod 0644 "${SCRIPT_DIR}/opensnitch/socket/.Xauthority" 2>/dev/null || true

        rm -f "${RUNTIME_DIR}/.Xauthority"
        if command -v xauth >/dev/null 2>&1; then
            xauth -f "${xauth_src}" nlist 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "${RUNTIME_DIR}/.Xauthority" nmerge - >/dev/null 2>&1 || cp -f "${xauth_src}" "${RUNTIME_DIR}/.Xauthority" 2>/dev/null || true
        else
            cp -f "${xauth_src}" "${RUNTIME_DIR}/.Xauthority" 2>/dev/null || true
        fi
        chmod 0644 "${RUNTIME_DIR}/.Xauthority" 2>/dev/null || true
    else
        touch "${SCRIPT_DIR}/opensnitch/socket/.Xauthority" "${RUNTIME_DIR}/.Xauthority"
        chmod 0644 "${SCRIPT_DIR}/opensnitch/socket/.Xauthority" "${RUNTIME_DIR}/.Xauthority" 2>/dev/null || true
    fi

    # Autorizza l'utente locale su XWayland/X11 se xhost è installato
    if command -v xhost >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        xhost "+SI:localuser:${HOST_USER}" >/dev/null 2>&1 || true
    fi
}

# ==============================================================================
# 2. VERIFICA E BUILD AUTOMATICO CON UID/GID DELL'UTENTE CORRENTE
# ==============================================================================
ensure_images_match_user() {
    local expected_base="ubuntu26.04"
    local ui_uid ui_base ui_ver agent_uid agent_base agent_gui fw_base
    ui_uid="$(docker inspect -f '{{index .Config.Labels "agentbox.uid"}}' agent-box-ui:local 2>/dev/null || true)"
    ui_base="$(docker inspect -f '{{index .Config.Labels "agentbox.base"}}' agent-box-ui:local 2>/dev/null || true)"
    ui_ver="$(docker inspect -f '{{index .Config.Labels "agentbox.version"}}' agent-box-ui:local 2>/dev/null || true)"
    agent_uid="$(docker inspect -f '{{index .Config.Labels "agentbox.uid"}}' agent-box-agent:local 2>/dev/null || true)"
    agent_base="$(docker inspect -f '{{index .Config.Labels "agentbox.base"}}' agent-box-agent:local 2>/dev/null || true)"
    agent_gui="$(docker inspect -f '{{index .Config.Labels "agentbox.gui"}}' agent-box-agent:local 2>/dev/null || true)"
    fw_base="$(docker inspect -f '{{index .Config.Labels "agentbox.base"}}' agent-box-firewall:local 2>/dev/null || true)"

    if [ "${ui_uid}" != "${PUID}" ] || [ "${ui_base}" != "${expected_base}" ] || [ "${ui_ver}" != "4" ] || \
       [ "${agent_uid}" != "${PUID}" ] || [ "${agent_base}" != "${expected_base}" ] || \
       [ "${agent_gui}" != "4" ] || [ "${fw_base}" != "${expected_base}" ]; then
        echo "[agent-box] Build automatico immagini Ubuntu 26.04 per ${HOST_USER} (UID=${PUID}, GID=${PGID})..."
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" build \
            --build-arg PUID="${PUID}" \
            --build-arg PGID="${PGID}"
    fi
}

# ==============================================================================
# 3. GENERAZIONE OVERRIDE RUNTIME (VOLUMI, GPU/iGPU, DISPLAY X11/WAYLAND)
# ==============================================================================
generate_runtime_override() {
    local gpu_mode="$1"
    local display_mode="$2"
    local shm_size="$3"
    local audio_mode="$4"
    local mic_mode="$5"
    shift 5
    local extra_volumes=("$@")

    local enable_audio=1
    case "${audio_mode}" in
        0|off|false|none|no)
            enable_audio=0
            ;;
        *)
            enable_audio=1
            ;;
    esac

    local enable_mic=0
    case "${mic_mode}" in
        1|on|true|yes)
            enable_mic=1
            enable_audio=1
            ;;
        *)
            enable_mic=0
            ;;
    esac

    local has_wayland=0
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        has_wayland=1
    fi
    local has_x11=0
    if [ -d /tmp/.X11-unix ]; then
        has_x11=1
    fi

    # Risolvi modalità display effettiva (sicura di default: Wayland-only oppure Xephyr :99 isolato)
    local use_wayland=0
    local use_xephyr=0
    local use_x11_unsafe=0
    local sess_type="x11"
    local qt_plat="xcb"
    local gdk_back="x11"
    local electron_hint="x11"
    local moz_wayland="0"
    local sdl_driver="x11"
    local host_disp_num="${DISPLAY#:}"
    host_disp_num="${host_disp_num%%.*}"
    host_disp_num="${host_disp_num:-0}"

    case "${display_mode}" in
        none|0|off|false)
            ;;
        wayland)
            if [ "${has_wayland}" -eq 1 ]; then
                use_wayland=1
                sess_type="wayland"
                qt_plat="wayland"
                gdk_back="wayland"
                electron_hint="wayland"
                moz_wayland="1"
                sdl_driver="wayland"
            else
                echo "[agent-box] ATTENZIONE: --display wayland richiesto ma socket Wayland non trovato in ${XDG_RUNTIME_DIR}."
            fi
            ;;
        isolated|xephyr|x11|xwayland)
            use_xephyr=1
            ;;
        x11-unsafe|xwayland-unsafe)
            if [ "${has_x11}" -eq 1 ]; then
                echo "[agent-box] ATTENZIONE SICUREZZA: modalità '${display_mode}' attiva! L'agente può vedere gli schermi X11 dell'host." >&2
                use_x11_unsafe=1
            else
                echo "[agent-box] ATTENZIONE: --display ${display_mode} richiesto ma /tmp/.X11-unix non trovato."
            fi
            ;;
        auto|*)
            if [ "${has_wayland}" -eq 1 ]; then
                # Su Wayland esponiamo SOLO Wayland (mai /tmp/.X11-unix dell'host) per impedire screenshot degli schermi host
                use_wayland=1
                sess_type="wayland"
                qt_plat="wayland"
                gdk_back="wayland"
                electron_hint="wayland"
                moz_wayland="1"
                sdl_driver="wayland"
            elif [ "${has_x11}" -eq 1 ]; then
                # Su X11 isoliamo l'agente in un server Xephyr dedicato (:99): gli screenshot vedono solo le finestre del container
                use_xephyr=1
            fi
            ;;
    esac

    # Risolvi dispositivi GPU / iGPU
    local devices_list=()
    local group_gids=()
    local enable_igpu=0
    local enable_nvidia=0
    local has_nvidia_runtime=0

    if ( [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1 ) && \
       docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'nvidia'; then
        has_nvidia_runtime=1
    fi

    case "${gpu_mode}" in
        none|0|off|false)
            ;;
        igpu)
            enable_igpu=1
            ;;
        nvidia)
            if [ "${has_nvidia_runtime}" -eq 1 ]; then
                enable_nvidia=1
            else
                echo "[agent-box] ATTENZIONE: --gpu nvidia richiesto ma runtime NVIDIA Docker non rilevato."
            fi
            ;;
        all)
            enable_igpu=1
            if [ "${has_nvidia_runtime}" -eq 1 ]; then
                enable_nvidia=1
            fi
            ;;
        auto|*)
            enable_igpu=1
            if [ "${has_nvidia_runtime}" -eq 1 ]; then
                enable_nvidia=1
            fi
            ;;
    esac

    if [ "${enable_igpu}" -eq 1 ]; then
        if [ -d /dev/dri ]; then
            devices_list+=("/dev/dri:/dev/dri")
            while IFS= read -r gid; do
                [ -n "${gid}" ] && [ "${gid}" != "0" ] && group_gids+=("${gid}")
            done < <(find /dev/dri -maxdepth 1 -type c -exec stat -c '%g' {} + 2>/dev/null | sort -u || true)
        fi
        if [ -e /dev/kfd ]; then
            devices_list+=("/dev/kfd:/dev/kfd")
            local kfd_gid
            kfd_gid="$(stat -c '%g' /dev/kfd 2>/dev/null || true)"
            [ -n "${kfd_gid}" ] && [ "${kfd_gid}" != "0" ] && group_gids+=("${kfd_gid}")
        fi
    fi

    # Risolvi dispositivi Audio / Microfono (sempre isolati tramite FIFO PCM unidirezionali,
    # senza mai esporre il socket PulseAudio/PipeWire dell'host o i device di cattura /dev/snd/pcmC*D*c ad agent)
    if [ "${enable_audio}" -eq 1 ]; then
        if [ -d /dev/snd ]; then
            for snd_dev in /dev/snd/controlC* /dev/snd/pcmC*D*p /dev/snd/timer /dev/snd/seq; do
                if [ -c "${snd_dev}" ]; then
                    devices_list+=("${snd_dev}:${snd_dev}")
                fi
            done
            while IFS= read -r gid; do
                [ -n "${gid}" ] && [ "${gid}" != "0" ] && group_gids+=("${gid}")
            done < <(find /dev/snd -maxdepth 1 -type c -exec stat -c '%g' {} + 2>/dev/null | sort -u || true)
        fi
    fi

    # Deduplica GIDs
    local unique_gids=()
    if [ "${#group_gids[@]}" -gt 0 ]; then
        while IFS= read -r g; do
            [ -n "${g}" ] && unique_gids+=("${g}")
        done < <(printf '%s\n' "${group_gids[@]}" | sort -u)
    fi

    # Scrivi il file YAML override
    {
        echo "services:"

        if [ "${use_xephyr}" -eq 1 ]; then
            echo "  opensnitch-ui:"
            echo "    environment:"
            echo "      - \"AGENT_XEPHYR_ENABLED=1\""
            echo "      - \"AGENT_XEPHYR_DISPLAY=:99\""
            echo "      - \"AGENT_SCREEN_SIZE=${AGENT_SCREEN_SIZE:-1600x900}\""
            echo "    volumes:"
            echo "      - \"${RUNTIME_DIR}/x11-isolated:/tmp/.X11-unix:rw\""
            if [ -S "/tmp/.X11-unix/X${host_disp_num}" ]; then
                echo "      - \"/tmp/.X11-unix/X${host_disp_num}:/tmp/.X11-unix/X${host_disp_num}:ro\""
            fi
        fi

        echo "  agent:"
        echo "    shm_size: \"${shm_size}\""
        echo "    tmpfs:"
        echo "      - /run/user/${PUID}:rw,noexec,nosuid,nodev,size=32m,uid=${PUID},gid=${PGID},mode=0700"

        # Volumi extra e socket grafici
        local vol_lines=()
        for vspec in "${extra_volumes[@]}"; do
            [ -z "${vspec}" ] && continue
            local host_p="" cont_p="" mode_p=""
            IFS=':' read -r host_p cont_p mode_p <<< "${vspec}"
            if [ -z "${host_p}" ] || [ -z "${cont_p}" ]; then
                echo "[agent-box] ATTENZIONE: volume non valido '${vspec}' (formato atteso host:container[:ro|rw])" >&2
                continue
            fi
            # Espandi ~
            if [[ "${host_p}" == "~/"* ]]; then
                host_p="${HOST_HOME}/${host_p#~/}"
            fi
            host_p="$(realpath -m "${host_p}")"
            if [ ! -e "${host_p}" ]; then
                mkdir -p "${host_p}"
            fi
            if [ -n "${mode_p}" ]; then
                vol_lines+=("${host_p}:${cont_p}:${mode_p}")
            else
                vol_lines+=("${host_p}:${cont_p}:rw")
            fi
        done

        if [ "${use_xephyr}" -eq 1 ]; then
            vol_lines+=("${RUNTIME_DIR}/x11-isolated:/tmp/.X11-unix:ro")
        elif [ "${use_x11_unsafe}" -eq 1 ]; then
            vol_lines+=("/tmp/.X11-unix:/tmp/.X11-unix:ro")
            vol_lines+=("${RUNTIME_DIR}/.Xauthority:/tmp/.Xauthority-host:ro")
        fi
        if [ "${use_wayland}" -eq 1 ]; then
            vol_lines+=("${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/run/user/${PUID}/${WAYLAND_DISPLAY}:rw")
        fi

        if [ "${#vol_lines[@]}" -gt 0 ]; then
            echo "    volumes:"
            for vl in "${vol_lines[@]}"; do
                echo "      - \"${vl}\""
            done
        fi

        if [ "${#devices_list[@]}" -gt 0 ]; then
            echo "    devices:"
            for dev in "${devices_list[@]}"; do
                echo "      - \"${dev}\""
            done
        fi

        if [ "${#unique_gids[@]}" -gt 0 ]; then
            echo "    group_add:"
            for gid in "${unique_gids[@]}"; do
                echo "      - \"${gid}\""
            done
        fi

        if [ "${enable_nvidia}" -eq 1 ]; then
            cat <<'EOF'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, graphics, utility, compute, display]
EOF
        fi

        # Variabili d'ambiente grafiche, GPU e Audio/Microfono
        local env_lines=()
        env_lines+=("AGENT_AUDIO=${enable_audio}")
        env_lines+=("AGENT_MIC=${enable_mic}")
        env_lines+=("AGENT_XEPHYR_ENABLED=${use_xephyr}")
        if [ "${enable_audio}" -eq 1 ]; then
            env_lines+=("PULSE_SERVER=unix:/run/user/${PUID}/pulse/native")
        fi
        if [ "${use_xephyr}" -eq 1 ] || [ "${use_x11_unsafe}" -eq 1 ] || [ "${use_wayland}" -eq 1 ]; then
            env_lines+=("XDG_RUNTIME_DIR=/run/user/${PUID}")
            env_lines+=("XDG_SESSION_TYPE=${sess_type}")
            env_lines+=("QT_QPA_PLATFORM=${qt_plat}")
            env_lines+=("QT_X11_NO_MITSHM=1")
            env_lines+=("GDK_BACKEND=${gdk_back}")
            env_lines+=("ELECTRON_OZONE_PLATFORM_HINT=${electron_hint}")
            env_lines+=("MOZ_ENABLE_WAYLAND=${moz_wayland}")
            env_lines+=("SDL_VIDEODRIVER=${sdl_driver}")
            if [ "${use_xephyr}" -eq 1 ]; then
                env_lines+=("DISPLAY=:99")
            elif [ "${use_x11_unsafe}" -eq 1 ]; then
                env_lines+=("DISPLAY=${DISPLAY}")
                env_lines+=("XAUTHORITY=/tmp/.Xauthority-host")
            fi
            if [ "${use_wayland}" -eq 1 ]; then
                env_lines+=("WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
            fi
        fi
        if [ "${enable_nvidia}" -eq 1 ]; then
            env_lines+=("NVIDIA_VISIBLE_DEVICES=all")
            env_lines+=("NVIDIA_DRIVER_CAPABILITIES=all")
        fi

        if [ "${#env_lines[@]}" -gt 0 ]; then
            echo "    environment:"
            for el in "${env_lines[@]}"; do
                echo "      - \"${el}\""
            done
        fi
    } > "${RUNTIME_OVERRIDE_FILE}"

    export AGENT_GPU_SUMMARY="iGPU=${enable_igpu}, NVIDIA=${enable_nvidia}"
    export AGENT_GUI_SUMMARY="mode=${display_mode} (Wayland=${use_wayland}, Xephyr-Isolato=${use_xephyr}, X11-Diretto=${use_x11_unsafe})"
    export AGENT_AUDIO_SUMMARY="Audio=${enable_audio}, Microfono=${enable_mic}"
    export AGENT_AUDIO="${enable_audio}"
    export AGENT_MIC="${enable_mic}"
}

start_stack() {
    local target_dir="${1:-${SCRIPT_DIR}/workspace}"
    detect_user_and_display
    ensure_images_match_user

    if [ ! -e "${target_dir}" ]; then
        mkdir -p "${target_dir}"
    fi
    export WORKSPACE_DIR="$(realpath "${target_dir}")"

    local project_env="${WORKSPACE_DIR}/.agent-box.env"

    # Carica configurazioni (priorità: CLI > .agent-box.env del progetto > env shell > .env)
    local host_cpus
    host_cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

    local req_cpus="${AGENT_CPUS:-}"
    [ -z "${req_cpus}" ] && req_cpus="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_CPUS")"
    local proj_cpus
    proj_cpus="$(read_env_var "${project_env}" "AGENT_CPUS")"
    [ -n "${proj_cpus}" ] && req_cpus="${proj_cpus}"
    [ -n "${CLI_CPUS}" ] && req_cpus="${CLI_CPUS}"

    if [ -z "${req_cpus}" ] || [ "${req_cpus}" = "all" ] || [ "${req_cpus}" = "ALL" ] || [ "${req_cpus}" = "0" ]; then
        export AGENT_CPUS="${host_cpus}"
    elif awk "BEGIN {exit !(${req_cpus} > ${host_cpus})}" 2>/dev/null; then
        export AGENT_CPUS="${host_cpus}"
    else
        export AGENT_CPUS="${req_cpus}"
    fi

    local mem_limit="${AGENT_MEM_LIMIT:-}"
    [ -z "${mem_limit}" ] && mem_limit="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_MEM_LIMIT")"
    local proj_mem
    proj_mem="$(read_env_var "${project_env}" "AGENT_MEM_LIMIT")"
    [ -n "${proj_mem}" ] && mem_limit="${proj_mem}"
    [ -n "${mem_limit}" ] && export AGENT_MEM_LIMIT="${mem_limit}"

    local shm_size="${AGENT_SHM_SIZE:-}"
    [ -z "${shm_size}" ] && shm_size="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_SHM_SIZE")"
    local proj_shm
    proj_shm="$(read_env_var "${project_env}" "AGENT_SHM_SIZE")"
    [ -n "${proj_shm}" ] && shm_size="${proj_shm}"
    shm_size="${shm_size:-512m}"
    export AGENT_SHM_SIZE="${shm_size}"

    local gpu_mode="${AGENT_GPU:-}"
    [ -z "${gpu_mode}" ] && gpu_mode="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_GPU")"
    local proj_gpu
    proj_gpu="$(read_env_var "${project_env}" "AGENT_GPU")"
    [ -n "${proj_gpu}" ] && gpu_mode="${proj_gpu}"
    [ -n "${CLI_GPU}" ] && gpu_mode="${CLI_GPU}"
    gpu_mode="${gpu_mode:-auto}"

    local display_mode="${AGENT_DISPLAY_MODE:-}"
    [ -z "${display_mode}" ] && display_mode="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_DISPLAY_MODE")"
    local proj_display
    proj_display="$(read_env_var "${project_env}" "AGENT_DISPLAY_MODE")"
    [ -n "${proj_display}" ] && display_mode="${proj_display}"
    [ -n "${CLI_DISPLAY_MODE}" ] && display_mode="${CLI_DISPLAY_MODE}"
    display_mode="${display_mode:-auto}"

    local screen_size="${AGENT_SCREEN_SIZE:-}"
    [ -z "${screen_size}" ] && screen_size="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_SCREEN_SIZE")"
    local proj_screen
    proj_screen="$(read_env_var "${project_env}" "AGENT_SCREEN_SIZE")"
    [ -n "${proj_screen}" ] && screen_size="${proj_screen}"
    export AGENT_SCREEN_SIZE="${screen_size:-1600x900}"

    local audio_mode="${AGENT_AUDIO:-}"
    [ -z "${audio_mode}" ] && audio_mode="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_AUDIO")"
    local proj_audio
    proj_audio="$(read_env_var "${project_env}" "AGENT_AUDIO")"
    [ -n "${proj_audio}" ] && audio_mode="${proj_audio}"
    [ -n "${CLI_AUDIO}" ] && audio_mode="${CLI_AUDIO}"
    audio_mode="${audio_mode:-1}"

    local mic_mode="${AGENT_MIC:-}"
    [ -z "${mic_mode}" ] && mic_mode="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_MIC")"
    local proj_mic
    proj_mic="$(read_env_var "${project_env}" "AGENT_MIC")"
    [ -n "${proj_mic}" ] && mic_mode="${proj_mic}"
    [ -n "${CLI_MIC}" ] && mic_mode="${CLI_MIC}"
    mic_mode="${mic_mode:-0}"

    local show_snitch_win="${OPENSNITCH_SHOW_MAIN_WINDOW:-}"
    [ -z "${show_snitch_win}" ] && show_snitch_win="$(read_env_var "${SCRIPT_DIR}/.env" "OPENSNITCH_SHOW_MAIN_WINDOW")"
    local proj_snitch
    proj_snitch="$(read_env_var "${project_env}" "OPENSNITCH_SHOW_MAIN_WINDOW")"
    [ -n "${proj_snitch}" ] && show_snitch_win="${proj_snitch}"
    export OPENSNITCH_SHOW_MAIN_WINDOW="${show_snitch_win:-1}"

    local fw_profile="${OPENSNITCH_PROFILE:-}"
    [ -z "${fw_profile}" ] && fw_profile="$(read_env_var "${SCRIPT_DIR}/.env" "OPENSNITCH_PROFILE")"
    local proj_fw_profile
    proj_fw_profile="$(read_env_var "${project_env}" "OPENSNITCH_PROFILE")"
    [ -n "${proj_fw_profile}" ] && fw_profile="${proj_fw_profile}"
    [ -n "${CLI_FW_PROFILE}" ] && fw_profile="${CLI_FW_PROFILE}"
    if [ -n "${fw_profile}" ]; then
        apply_opensnitch_profile "${fw_profile}"
    fi

    # Volumi extra (.env + .agent-box.env + CLI -v)
    local raw_vols=""
    local env_vols proj_vols
    env_vols="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_EXTRA_VOLUMES")"
    proj_vols="$(read_env_var "${project_env}" "AGENT_EXTRA_VOLUMES")"
    raw_vols="${AGENT_EXTRA_VOLUMES:-${env_vols}}"
    if [ -n "${proj_vols}" ]; then
        raw_vols="${raw_vols:+${raw_vols},}${proj_vols}"
    fi

    local all_extra_vols=()
    if [ -n "${raw_vols}" ]; then
        local normalized_vols="${raw_vols//;/,}"
        IFS=',' read -ra parsed_vols <<< "${normalized_vols}"
        for item in "${parsed_vols[@]}"; do
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"
            [ -n "${item}" ] && all_extra_vols+=("${item}")
        done
    fi
    if [ "${#CLI_EXTRA_VOLUMES[@]}" -gt 0 ]; then
        all_extra_vols+=("${CLI_EXTRA_VOLUMES[@]}")
    fi

    # Supporto opzionale per endpoint HTTPS locali con certificato self-signed senza CA in ./certs
    local tls_insecure="${AGENT_TLS_INSECURE:-}"
    [ -z "${tls_insecure}" ] && tls_insecure="$(read_env_var "${SCRIPT_DIR}/.env" "AGENT_TLS_INSECURE")"
    local proj_tls
    proj_tls="$(read_env_var "${project_env}" "AGENT_TLS_INSECURE")"
    [ -n "${proj_tls}" ] && tls_insecure="${proj_tls}"
    if [ "${tls_insecure}" = "1" ]; then
        export NODE_TLS_REJECT_UNAUTHORIZED=0
    fi

    generate_runtime_override "${gpu_mode}" "${display_mode}" "${shm_size}" "${audio_mode}" "${mic_mode}" "${all_extra_vols[@]}"

    echo "[agent-box] Utente rilevato : ${HOST_USER} (UID=${PUID}, GID=${PGID})"
    echo "[agent-box] Sessione grafica: ${XDG_SESSION_TYPE} | Agente GUI: ${AGENT_GUI_SUMMARY}"
    echo "[agent-box] Risorse CPU/GPU : ${AGENT_CPUS}/${host_cpus} core | ${AGENT_GPU_SUMMARY} | ${AGENT_AUDIO_SUMMARY}"
    echo "[agent-box] Workspace       : ${WORKSPACE_DIR}"
    if [ "${#all_extra_vols[@]}" -gt 0 ]; then
        echo "[agent-box] Volumi extra    : ${all_extra_vols[*]}"
    fi

    dc up -d opensnitch-ui firewall agent

    # Verifica rapida che i container critici non siano andati subito in crash
    sleep 1
    local fw_state
    fw_state="$(docker inspect -f '{{.State.Status}}' agent-box-firewall 2>/dev/null || echo "missing")"
    if [ "${fw_state}" != "running" ]; then
        echo "[agent-box] ERRORE: il container 'firewall' non è in esecuzione (stato: ${fw_state}). Log:"
        dc logs --tail=30 firewall
        exit 1
    fi

    # Assicura che host.docker.internal risolva verso il gateway Docker in ./hosts (se non già definito manualmente)
    local gw_ip
    gw_ip="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' agent-box_agent_net 2>/dev/null || true)"
    if [ -n "${gw_ip}" ] && ! grep -qE '[[:space:]]host\.docker\.internal([[:space:]]|$)' "${SCRIPT_DIR}/hosts" 2>/dev/null; then
        echo "${gw_ip} host.docker.internal" >> "${SCRIPT_DIR}/hosts"
    fi
}

run_test_popup() {
    start_stack "${SCRIPT_DIR}/workspace"
    echo ""
    echo "=================================================================="
    echo " 🔔 TEST POPUP OPENSNITCH SU WAYLAND / XWAYLAND"
    echo "=================================================================="
    echo "1. Verifica socket tra opensnitch-ui e opensnitchd:"
    if [ -S "${SCRIPT_DIR}/opensnitch/socket/osui.sock" ]; then
        ls -la "${SCRIPT_DIR}/opensnitch/socket/osui.sock"
        echo "   [OK] Socket osui.sock attivo!"
    else
        echo "   [ERRORE] Socket osui.sock non trovato. Log di opensnitch-ui:"
        dc logs --tail=30 opensnitch-ui
        exit 1
    fi
    echo ""
    echo "2. Invio richiesta HTTP di test dall'agente verso https://example.com ..."
    echo "   👉 Dovresti vedere apparire ora il popup di OpenSnitch sul desktop!"
    dc exec agent curl -I -sS --max-time 25 https://example.com || echo "   [Connessione bloccata o rifiutata da OpenSnitch]"
    echo "=================================================================="
}

run_security_audit() {
    start_stack "${SCRIPT_DIR}/workspace"
    echo ""
    echo "=================================================================="
    echo " 🔍 AUDIT DI SICUREZZA E ISOLAMENTO (Eseguito dentro 'agent')"
    echo "=================================================================="
    dc exec agent bash -c '
        echo "1. Utente corrente (non-root):"
        id
        echo ""
        echo "2. Capabilities del kernel (devono essere tutte 0000000000000000):"
        grep -E "^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs):" /proc/self/status
        echo ""
        echo "3. Verifica Root Filesystem in sola lettura (read_only: true):"
        if touch /test_ro 2>/dev/null; then
            echo "   [FAIL] Root filesystem scrivibile!"
            rm -f /test_ro
        else
            echo "   [OK] Scrittura su / bloccata (Read-only file system)"
        fi
        echo ""
        echo "4. Verifica isolamento socket OpenSnitch UI (/run/opensnitch/osui.sock):"
        if [ -e /run/opensnitch/osui.sock ]; then
            echo "   [FAIL] Socket OpenSnitch visibile dall agente!"
        else
            echo "   [OK] Socket OpenSnitch invisibile all agente (nessuna auto-approvazione possibile)"
        fi
        echo ""
        echo "5. Tentativo di uccidere opensnitchd dall agente (deve fallire con Operation not permitted):"
        SNITCH_PID=$(pgrep -x opensnitchd || true)
        if [ -n "$SNITCH_PID" ]; then
            if kill -9 "$SNITCH_PID" 2>/dev/null; then
                echo "   [FAIL] L agente è riuscito a terminare opensnitchd!"
            else
                echo "   [OK] kill -9 su opensnitchd (PID $SNITCH_PID) bloccato dal kernel (EPERM)"
            fi
        else
            echo "   [INFO] PID namespace isolato o opensnitchd non visibile"
        fi
    '
    echo "=================================================================="
}

# Parsing opzioni globali prima del sottocomando
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--volume)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: $1 richiede un argomento (host:container[:ro|rw])." >&2
                exit 1
            fi
            CLI_EXTRA_VOLUMES+=("$2")
            shift 2
            ;;
        --volume=*)
            CLI_EXTRA_VOLUMES+=("${1#*=}")
            shift
            ;;
        --cpus)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: --cpus richiede un argomento." >&2
                exit 1
            fi
            CLI_CPUS="$2"
            shift 2
            ;;
        --cpus=*)
            CLI_CPUS="${1#*=}"
            shift
            ;;
        --gpu)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: --gpu richiede un argomento (auto|all|igpu|nvidia|none)." >&2
                exit 1
            fi
            CLI_GPU="$2"
            shift 2
            ;;
        --gpu=*)
            CLI_GPU="${1#*=}"
            shift
            ;;
        --display)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: --display richiede un argomento (auto|wayland|xwayland|x11|none)." >&2
                exit 1
            fi
            CLI_DISPLAY_MODE="$2"
            shift 2
            ;;
        --display=*)
            CLI_DISPLAY_MODE="${1#*=}"
            shift
            ;;
        --no-gui)
            CLI_DISPLAY_MODE="none"
            shift
            ;;
        --audio)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: --audio richiede un argomento (on|off|1|0)." >&2
                exit 1
            fi
            CLI_AUDIO="$2"
            shift 2
            ;;
        --audio=*)
            CLI_AUDIO="${1#*=}"
            shift
            ;;
        --no-audio)
            CLI_AUDIO="0"
            CLI_MIC="0"
            shift
            ;;
        --mic)
            if [ $# -ge 2 ] && [[ "$2" =~ ^(on|off|1|0|true|false|yes|no)$ ]]; then
                CLI_MIC="$2"
                shift 2
            else
                CLI_MIC="1"
                shift
            fi
            ;;
        --mic=*)
            CLI_MIC="${1#*=}"
            shift
            ;;
        --no-mic)
            CLI_MIC="0"
            shift
            ;;
        --fw-profile)
            if [ $# -lt 2 ]; then
                echo "[agent-box] ERRORE: --fw-profile richiede un argomento." >&2
                exit 1
            fi
            CLI_FW_PROFILE="$2"
            shift 2
            ;;
        --fw-profile=*)
            CLI_FW_PROFILE="${1#*=}"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[agent-box] ERRORE: opzione sconosciuta '$1'." >&2
            print_usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

run_agent_cmd() {
    local agent_bin="$1"
    shift
    local target="${SCRIPT_DIR}/workspace"
    if [ -d "${1:-}" ]; then
        target="$1"
        shift
    fi
    start_stack "${target}"
    dc exec agent bash -c '"$1" "${@:2}"; status=$?; echo ""; echo "[agent-box] Sessione $1 terminata (exit $status). Sei nella shell del container (digita exit per uscire)."; exec bash' _ "${agent_bin}" "$@"
}

CMD="${1:-shell}"
shift || true

case "${CMD}" in
    build)
        detect_user_and_display
        echo "[agent-box] Build immagini per ${HOST_USER} (UID=${PUID}, GID=${PGID})..."
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" build \
            --build-arg PUID="${PUID}" \
            --build-arg PGID="${PGID}" \
            "$@"
        ;;
    shell|sh|bash)
        TARGET="${1:-${SCRIPT_DIR}/workspace}"
        start_stack "${TARGET}"
        dc exec agent bash
        ;;
    claude|grok|agy|pi|gemini|opencode|aider|hermes|\
    claude-desktop|claude-gui|\
    chatgpt-desktop|chatgpt-gui|codex-desktop|codex-gui|\
    opencode-desktop|opencode-gui|opencode-web|\
    aider-desktop|aider-gui|\
    grok-desktop|grok-gui|\
    gemini-desktop|gemini-gui|\
    agy-desktop|agy-gui|antigravity-desktop|antigravity-gui|\
    pi-desktop|pi-gui|\
    hermes-desktop|hermes-gui)
        run_agent_cmd "${CMD}" "$@"
        ;;
    chatgpt|codex)
        run_agent_cmd codex "$@"
        ;;
    exec)
        if [ -d "${1:-}" ]; then
            TARGET="$1"
            shift
        else
            TARGET="${SCRIPT_DIR}/workspace"
        fi
        start_stack "${TARGET}"
        dc exec agent "$@"
        ;;
    apt|apt-get)
        start_stack "${SCRIPT_DIR}/workspace"
        dc exec agent agent-apt "$@"
        ;;
    test-popup|popup)
        run_test_popup
        ;;
    test-isolation|audit)
        run_security_audit
        ;;
    fw-profile|rules)
        if [ -z "${1:-}" ] || [ "${1:-}" = "list" ]; then
            echo "Profili regole OpenSnitch disponibili in ./opensnitch-profiles (e in /home/snitch/opensnitch-profiles nella GUI):"
            for pdir in "${SCRIPT_DIR}/opensnitch-profiles"/*; do
                [ -d "${pdir}" ] && echo "  - $(basename "${pdir}") ($(ls -1 "${pdir}"/*.json 2>/dev/null | wc -l) regole)"
            done
            echo ""
            echo "Regole attualmente presenti in ./opensnitch/rules:"
            ls -1 "${SCRIPT_DIR}/opensnitch/rules"/*.json 2>/dev/null | xargs -r -n1 basename || echo "  (nessuna)"
        else
            apply_opensnitch_profile "$1"
            if [ "$(docker inspect -f '{{.State.Status}}' agent-box-firewall 2>/dev/null || true)" = "running" ]; then
                echo "[agent-box] Riavvio container firewall per applicare immediatamente le nuove regole..."
                dc restart firewall
            fi
        fi
        ;;
    stop|down)
        detect_user_and_display
        dc down
        ;;
    logs)
        detect_user_and_display
        dc logs -f "$@"
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
