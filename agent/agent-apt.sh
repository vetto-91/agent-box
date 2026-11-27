#!/usr/bin/env bash
set -euo pipefail

INVOKED_AS="$(basename "$0")"

# 1. Se invocato come 'sudo', filtra i flag di sudo ed esegue agent-apt o il comando
if [ "${INVOKED_AS}" = "sudo" ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            -E|-n|-S|-H|-i|-s)
                shift
                ;;
            -u|-g|-p)
                shift 2 || true
                ;;
            --)
                shift
                break
                ;;
            -*)
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    if [ $# -eq 0 ]; then
        exit 0
    fi
    TARGET_CMD="$(basename "$1")"
    if [ "${TARGET_CMD}" = "apt" ] || [ "${TARGET_CMD}" = "apt-get" ] || [ "${TARGET_CMD}" = "agent-apt" ]; then
        shift
        INVOKED_AS="${TARGET_CMD}"
    else
        exec "$@"
    fi
fi

# 2. Se eseguito come root (es. durante docker build), delega ai binari reali in /usr/bin
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    if [ "${INVOKED_AS}" = "apt" ]; then
        exec /usr/bin/apt "$@"
    else
        exec /usr/bin/apt-get "$@"
    fi
fi

# 3. Modalità rootless dentro il container agent (read_only: true, cap_drop: ALL, no-new-privileges)
SYSROOT="${HOME}/.local/sysroot"
APT_TMP="/tmp/agent-apt-$(id -u)"
APT_CONF_DIR="${APT_TMP}/apt.conf.d"
STATUS_FILE="${SYSROOT}/var/lib/dpkg/status"

mkdir -p \
    "${SYSROOT}/var/lib/dpkg" \
    "${SYSROOT}/usr/bin" \
    "${SYSROOT}/usr/include" \
    "${SYSROOT}/usr/lib" \
    "${APT_TMP}/lists/partial" \
    "${APT_TMP}/cache/archives/partial" \
    "${APT_CONF_DIR}"

# Copia le configurazioni apt escludendo docker-clean (che tenta rm in /var/cache/apt read-only)
for conf in /etc/apt/apt.conf.d/*; do
    [ -f "${conf}" ] || continue
    bname="$(basename "${conf}")"
    [ "${bname}" = "docker-clean" ] && continue
    cp -f "${conf}" "${APT_CONF_DIR}/${bname}" 2>/dev/null || true
done

# Evita il warning di duplicazione tra chatgpt.list e chatgpt.sources preparando una sources.list.d pulita
APT_SOURCES_DIR="${APT_TMP}/sources.list.d"
mkdir -p "${APT_SOURCES_DIR}"
rm -f "${APT_SOURCES_DIR}/"*
for src in /etc/apt/sources.list.d/*; do
    [ -f "${src}" ] || continue
    bname="$(basename "${src}")"
    if [ "${bname}" = "chatgpt.list" ] && [ -f /etc/apt/sources.list.d/chatgpt.sources ]; then
        continue
    fi
    cp -f "${src}" "${APT_SOURCES_DIR}/${bname}"
done

if [ ! -f "${STATUS_FILE}" ]; then
    cp -f /var/lib/dpkg/status "${STATUS_FILE}"
fi

APT_OPTS=(
    -o Dir::State::lists="${APT_TMP}/lists"
    -o Dir::Cache="${APT_TMP}/cache"
    -o Dir::Cache::archives="${APT_TMP}/cache/archives"
    -o Dir::State::status="${STATUS_FILE}"
    -o Dir::Etc::Parts="${APT_CONF_DIR}"
    -o Dir::Etc::sourceparts="${APT_SOURCES_DIR}"
    -o Dir::Log="${APT_TMP}"
    -o APT::Sandbox::User="$(id -un)"
    -o Debug::NoLocking=true
)

ensure_apt_lists() {
    if [ -z "$(find "${APT_TMP}/lists" -maxdepth 1 -type f 2>/dev/null | head -n 1)" ]; then
        echo "[agent-apt] Aggiornamento indici dei pacchetti (apt update)..."
        /usr/bin/apt-get "${APT_OPTS[@]}" update
    fi
}

fix_sysroot_links_and_pkgconfig() {
    # Risolve i symlink relativi rotti in $SYSROOT che puntano a librerie presenti nell'immagine base (/usr o /lib)
    while IFS= read -r -d '' link; do
        if [ ! -e "${link}" ]; then
            local rel_path="${link#${SYSROOT}}"
            local target
            target="$(readlink "${link}")"
            local resolved
            resolved="$(realpath -m "$(dirname "${rel_path}")/${target}")"
            if [ -e "${SYSROOT}${resolved}" ]; then
                ln -snf "${SYSROOT}${resolved}" "${link}"
            elif [ -e "${resolved}" ]; then
                ln -snf "${resolved}" "${link}"
            fi
        fi
    done < <(find "${SYSROOT}" -type l -print0 2>/dev/null)

    # Aggiorna i prefissi nei file .pc di pkg-config estratti nel sysroot
    for pc in "${SYSROOT}"/usr/lib/*/pkgconfig/*.pc "${SYSROOT}"/usr/lib/pkgconfig/*.pc "${SYSROOT}"/usr/share/pkgconfig/*.pc; do
        [ -f "${pc}" ] || continue
        sed -i \
            -e "s|^prefix=/usr$|prefix=${SYSROOT}/usr|g" \
            -e "s|^libdir=/usr/lib|libdir=${SYSROOT}/usr/lib|g" \
            -e "s|^includedir=/usr/include|includedir=${SYSROOT}/usr/include|g" \
            "${pc}"
    done
}

record_installed_deb() {
    local deb="$1"
    local pkg_name
    pkg_name="$(dpkg-deb -f "${deb}" Package 2>/dev/null || true)"
    [ -z "${pkg_name}" ] && return 0

    # Registra nel file di stato dpkg del sysroot se non già presente come installato
    if ! grep -q "^Package: ${pkg_name}$" "${STATUS_FILE}" 2>/dev/null; then
        {
            echo ""
            dpkg-deb -f "${deb}"
            echo "Status: install ok installed"
        } >> "${STATUS_FILE}"
    fi
    touch "${SYSROOT}/installed-packages.txt"
    if ! grep -qx "${pkg_name}" "${SYSROOT}/installed-packages.txt" 2>/dev/null; then
        echo "${pkg_name}" >> "${SYSROOT}/installed-packages.txt"
    fi
}

# Individua il sottocomando apt (update, install, search, show, policy, clean, ecc.)
SUBCMD=""
for arg in "$@"; do
    case "${arg}" in
        -*)
            ;;
        *)
            SUBCMD="${arg}"
            break
            ;;
    esac
done

case "${SUBCMD}" in
    update)
        exec /usr/bin/apt-get "${APT_OPTS[@]}" "$@"
        ;;
    install|reinstall)
        ensure_apt_lists
        rm -f "${APT_TMP}/cache/archives/"*.deb
        /usr/bin/apt-get "${APT_OPTS[@]}" --download-only "$@"

        DEB_COUNT=0
        for deb in "${APT_TMP}/cache/archives/"*.deb; do
            [ -f "${deb}" ] || continue
            DEB_COUNT=$((DEB_COUNT + 1))
            echo "[agent-apt] Estrazione $(basename "${deb}") in ${SYSROOT} ..."
            dpkg-deb -x "${deb}" "${SYSROOT}"
            record_installed_deb "${deb}"
        done

        if [ "${DEB_COUNT}" -gt 0 ]; then
            fix_sysroot_links_and_pkgconfig
            # Non lasciare in sysroot/usr/bin wrapper GUI che scavalcano /usr/local/bin/* (--no-sandbox)
            rm -f \
                "${SYSROOT}/usr/bin/claude-desktop" \
                "${SYSROOT}/usr/bin/chatgpt" \
                "${SYSROOT}/usr/bin/opencode-desktop" \
                "${SYSROOT}/usr/bin/ai.opencode" \
                "${SYSROOT}/usr/bin/ai.opencode.desktop" 2>/dev/null || true
            rm -f "${APT_TMP}/cache/archives/"*.deb
            echo "[agent-apt] Installati ${DEB_COUNT} pacchetti in ${SYSROOT} (persistenti in ./agent-home)."
        else
            echo "[agent-apt] Nessun nuovo pacchetto da estrarre."
        fi
        ;;
    search|show|policy|depends|rdepends)
        ensure_apt_lists
        exec /usr/bin/apt-cache "${APT_OPTS[@]}" "$@"
        ;;
    clean|autoclean)
        rm -rf "${APT_TMP}/cache/archives/"*.deb
        echo "[agent-apt] Cache pacchetti pulita."
        ;;
    list-installed)
        if [ -f "${SYSROOT}/installed-packages.txt" ]; then
            cat "${SYSROOT}/installed-packages.txt"
        else
            echo "[agent-apt] Nessun pacchetto extra installato in ${SYSROOT}."
        fi
        ;;
    reset-sysroot)
        rm -rf "${SYSROOT}"
        echo "[agent-apt] Sysroot ${SYSROOT} rimosso."
        ;;
    *)
        ensure_apt_lists
        exec /usr/bin/apt "${APT_OPTS[@]}" "$@"
        ;;
esac
