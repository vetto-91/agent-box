#!/bin/sh
set -eu

RULES_DIR="/etc/opensnitchd/rules"
SOCKET_DIR="/run/opensnitch"
SOCKET_PATH="${SOCKET_DIR}/osui.sock"
CUSTOM_HOSTS_FILE="/etc/agent-box/hosts"
RULE_TS="2026-01-01T00:00:00.000000Z"
mkdir -p "${RULES_DIR}" "${SOCKET_DIR}"

echo "[firewall] Configurazione iptables Fail-Closed (nessun traffico senza OpenSnitch)..."

# Seleziona il backend iptables funzionante (nft o legacy, per compatibilità tra kernel/distro diverse)
IPT="iptables"
IP6T="ip6tables"
if ! "${IPT}" -t mangle -L >/dev/null 2>&1; then
    if command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -t mangle -L >/dev/null 2>&1; then
        echo "[firewall] iptables (nft) non supportato dal kernel host, fallback su iptables-legacy."
        IPT="iptables-legacy"
        IP6T="ip6tables-legacy"
    else
        echo "[firewall] ERRORE CRITICO: né iptables-nft né iptables-legacy funzionano in questo container."
        echo "[firewall] Verifica che i moduli kernel (nf_tables / ip_tables, iptable_mangle, xt_NFQUEUE) siano disponibili sull'host."
        exit 1
    fi
fi

# 1. Blocca completamente IPv6 per evitare leak fuori da OpenSnitch IPv4 (se IPv6 è attivo sul kernel)
if [ -e /proc/net/if_inet6 ] && "${IP6T}" -L >/dev/null 2>&1; then
    "${IP6T}" -F
    "${IP6T}" -X
    "${IP6T}" -t mangle -F 2>/dev/null || true
    "${IP6T}" -P INPUT DROP
    "${IP6T}" -P FORWARD DROP
    "${IP6T}" -P OUTPUT DROP
    "${IP6T}" -A INPUT -i lo -j ACCEPT
    "${IP6T}" -A OUTPUT -o lo -j ACCEPT
else
    echo "[firewall] IPv6 non attivo o ip6tables non disponibile sul kernel host: salto configurazione ip6tables."
fi

# 2. Configura IPv4 Fail-Closed
"${IPT}" -F
"${IPT}" -X
"${IPT}" -t mangle -F

# Policy di default su filter
"${IPT}" -P INPUT DROP
"${IPT}" -P FORWARD DROP
"${IPT}" -P OUTPUT ACCEPT

# INPUT: consenti loopback e connessioni già stabilite/approvate
"${IPT}" -A INPUT -i lo -j ACCEPT
"${IPT}" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 3. Regola permanente OpenSnitch per traffico loopback (127.0.0.0/8)
cat <<EOF > "${RULES_DIR}/000-allow-loopback.json"
{
  "created": "${RULE_TS}",
  "updated": "${RULE_TS}",
  "name": "000-allow-loopback",
  "description": "Consenti traffico loopback locale (127.0.0.0/8)",
  "enabled": true,
  "precedence": true,
  "nolog": false,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "network",
    "operand": "dest.network",
    "data": "127.0.0.0/8",
    "sensitive": false
  }
}
EOF

# 4. Gestione AUTO_DNS (evita il doppio popup per la risoluzione DNS su porta 53)
if [ "${AUTO_DNS:-1}" = "1" ]; then
    echo "[firewall] AUTO_DNS=1 attivo: creazione regola OpenSnitch per consentire query DNS (porta 53)."
    cat <<EOF > "${RULES_DIR}/001-auto-dns.json"
{
  "created": "${RULE_TS}",
  "updated": "${RULE_TS}",
  "name": "001-auto-dns",
  "description": "Consenti risoluzione DNS (porta 53)",
  "enabled": true,
  "precedence": true,
  "nolog": false,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "simple",
    "operand": "dest.port",
    "data": "53",
    "sensitive": false
  }
}
EOF
else
    echo "[firewall] AUTO_DNS=0: anche le singole query DNS richiederanno approvazione su OpenSnitch."
    rm -f "${RULES_DIR}/001-auto-dns.json"
fi

# 5. Regole ad-hoc prioritarie (010..019, precedence: true) per gli endpoint di rete
#    configurati in .env / .agent-box.env (OLLAMA_HOST, OLLAMA_API_BASE, LOCAL_LLM_BASE_URL, OPENAI_BASE_URL).
#    Vengono valutate PRIMA delle regole di profilo (100-deny-lan-*, 200-*, 999-deny-*):
#    se un profilo blocca la LAN ma Ollama/LLM è in LAN, apre SOLO quell'IP/host e quella porta.
rm -f "${RULES_DIR}"/002-allow-ollama.json "${RULES_DIR}"/01*-allow-env-*.json

is_ipv4() {
    printf '%s\n' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

resolve_ipv4_list() {
    _host="$1"
    _local_ips="$({
        if [ -r "${CUSTOM_HOSTS_FILE}" ]; then
            awk -v h="${_host}" '
                /^[[:space:]]*#/ || NF < 2 { next }
                {
                    ip = $1
                    if (ip ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                        for (i = 2; i <= NF; i++) {
                            if (tolower($i) == tolower(h)) {
                                print ip
                            }
                        }
                    }
                }
            ' "${CUSTOM_HOSTS_FILE}" 2>/dev/null || true
        fi
        if [ -r /etc/hosts ]; then
            awk -v h="${_host}" '
                /^[[:space:]]*#/ || NF < 2 { next }
                {
                    ip = $1
                    if (ip ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                        for (i = 2; i <= NF; i++) {
                            if (tolower($i) == tolower(h)) {
                                print ip
                            }
                        }
                    }
                }
            ' /etc/hosts 2>/dev/null || true
        fi
    } | awk '!seen[$0]++')"

    if [ -n "${_local_ips}" ]; then
        printf '%s\n' "${_local_ips}"
        return 0
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout 2 getent ahostsv4 "${_host}" 2>/dev/null | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk '!seen[$0]++' || true
    else
        getent ahostsv4 "${_host}" 2>/dev/null | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk '!seen[$0]++' || true
    fi
}

write_env_endpoint_rule() {
    _rule_name="$1"
    _desc="$2"
    _operand="$3"
    _op_type="$4"
    _target="$5"
    _port="$6"
    cat <<EOF > "${RULES_DIR}/${_rule_name}.json"
{
  "created": "${RULE_TS}",
  "updated": "${RULE_TS}",
  "name": "${_rule_name}",
  "description": "${_desc}",
  "enabled": true,
  "precedence": true,
  "nolog": false,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "list",
    "operand": "list",
    "data": "",
    "sensitive": false,
    "list": [
      {
        "type": "${_op_type}",
        "operand": "${_operand}",
        "data": "${_target}",
        "sensitive": false
      },
      {
        "type": "simple",
        "operand": "dest.port",
        "data": "${_port}",
        "sensitive": false
      }
    ]
  }
}
EOF
}

SEEN_ENDPOINTS=" "
add_env_endpoint_rules() {
    _prefix="$1"
    _label="$2"
    _raw_url="$3"
    _default_port="$4"

    # Trim spazi
    _url="$(printf '%s' "${_raw_url}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "${_url}" ] || return 0

    _scheme=""
    _rest="${_url}"
    case "${_url}" in
        https://*)
            _scheme="https"
            _rest="${_url#https://}"
            ;;
        http://*)
            _scheme="http"
            _rest="${_url#http://}"
            ;;
        *://*)
            _scheme="${_url%%://*}"
            _rest="${_url#*://}"
            ;;
    esac

    # Rimuovi path, query, fragment e credenziali eventuali
    _authority="${_rest%%/*}"
    _authority="${_authority%%\?*}"
    _authority="${_authority%%\#*}"
    _authority="${_authority##*@}"
    [ -n "${_authority}" ] || return 0

    # Ignora IPv6 bracketed (IPv6 è bloccato a livello ip6tables)
    case "${_authority}" in
        \[*)
            echo "[firewall] AVVISO: endpoint ${_label} '${_raw_url}' usa IPv6 (bloccato da ip6tables), salto regola."
            return 0
            ;;
    esac

    _host="${_authority}"
    _port=""
    case "${_authority}" in
        *:*)
            _host="${_authority%:*}"
            _port="${_authority##*:}"
            ;;
    esac

    if [ -z "${_port}" ]; then
        if [ "${_scheme}" = "https" ]; then
            _port="443"
        elif [ "${_scheme}" = "http" ]; then
            _port="80"
        else
            _port="${_default_port}"
        fi
    fi

    # Validazione base host e porta numerica
    if [ -z "${_host}" ] || ! printf '%s\n' "${_port}" | grep -Eq '^[0-9]{1,5}$'; then
        echo "[firewall] AVVISO: impossibile parsare endpoint ${_label} '${_raw_url}', salto regola."
        return 0
    fi

    # Loopback è già consentito da 000-allow-loopback
    case "${_host}" in
        localhost|127.*)
            return 0
            ;;
    esac

    _dedup_key="${_host}:${_port}"
    case "${SEEN_ENDPOINTS}" in
        *" ${_dedup_key} "*)
            return 0
            ;;
    esac
    SEEN_ENDPOINTS="${SEEN_ENDPOINTS}${_dedup_key} "

    if is_ipv4 "${_host}"; then
        write_env_endpoint_rule \
            "${_prefix}-ip" \
            "Priorità .env (${_label}): consenti ${_host}:${_port}" \
            "dest.ip" "simple" "${_host}" "${_port}"
        echo "[firewall] Regola prioritaria .env (${_label}): consenti IP ${_host}:${_port}"
    else
        # 1) Regola su dest.host (match su risoluzioni DNS dinamiche/CDN)
        write_env_endpoint_rule \
            "${_prefix}-host" \
            "Priorità .env (${_label}): consenti host ${_host}:${_port}" \
            "dest.host" "simple" "${_host}" "${_port}"
        echo "[firewall] Regola prioritaria .env (${_label}): consenti host ${_host}:${_port}"

        # 2) Regola su dest.ip risolto (fondamentale per /etc/hosts, host.docker.internal, ./hosts)
        _ips="$(resolve_ipv4_list "${_host}")"
        if [ -n "${_ips}" ]; then
            _ip_count="$(printf '%s\n' "${_ips}" | wc -l | tr -d ' ')"
            if [ "${_ip_count}" -eq 1 ]; then
                write_env_endpoint_rule \
                    "${_prefix}-ip" \
                    "Priorità .env (${_label}): consenti ${_host} -> ${_ips}:${_port}" \
                    "dest.ip" "simple" "${_ips}" "${_port}"
                echo "[firewall] Regola prioritaria .env (${_label}): consenti IP risolto ${_ips}:${_port} (${_host})"
            else
                _ip_regex="^($(printf '%s\n' "${_ips}" | sed 's/\./\\./g' | paste -sd'|' -))$"
                write_env_endpoint_rule \
                    "${_prefix}-ip" \
                    "Priorità .env (${_label}): consenti ${_host} -> IP risolti:${_port}" \
                    "dest.ip" "regexp" "${_ip_regex}" "${_port}"
                echo "[firewall] Regola prioritaria .env (${_label}): consenti IP risolti (${_ip_count}) per ${_host}:${_port}"
            fi
        fi
    fi
}

if [ "${AUTO_ALLOW_ENV_ENDPOINTS:-1}" = "1" ]; then
    DEFAULT_OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    DEFAULT_OLLAMA_URL="http://host.docker.internal:${DEFAULT_OLLAMA_PORT}"

    # Per Ollama: crea sempre la regola ad-hoc (IP/host + porta) se AUTO_ALLOW_OLLAMA=1
    # OPPURE se l'utente ha configurato un endpoint Ollama personalizzato in .env
    if [ -n "${OLLAMA_HOST:-}" ]; then
        if [ "${AUTO_ALLOW_OLLAMA:-1}" = "1" ] || [ "${OLLAMA_HOST}" != "${DEFAULT_OLLAMA_URL}" ]; then
            add_env_endpoint_rules "010-allow-env-ollama" "OLLAMA_HOST" "${OLLAMA_HOST}" "${DEFAULT_OLLAMA_PORT}"
        fi
    fi
    if [ -n "${OLLAMA_API_BASE:-}" ]; then
        if [ "${AUTO_ALLOW_OLLAMA:-1}" = "1" ] || [ "${OLLAMA_API_BASE}" != "${DEFAULT_OLLAMA_URL}" ]; then
            add_env_endpoint_rules "011-allow-env-ollama-api" "OLLAMA_API_BASE" "${OLLAMA_API_BASE}" "${DEFAULT_OLLAMA_PORT}"
        fi
    fi
    if [ -n "${LOCAL_LLM_BASE_URL:-}" ]; then
        add_env_endpoint_rules "012-allow-env-local-llm" "LOCAL_LLM_BASE_URL" "${LOCAL_LLM_BASE_URL}" "80"
    fi
    if [ -n "${OPENAI_BASE_URL:-}" ]; then
        add_env_endpoint_rules "013-allow-env-openai-base" "OPENAI_BASE_URL" "${OPENAI_BASE_URL}" "443"
    fi
fi

# 6. Attiva MANGLE OUTPUT Fail-Closed (DOPO l'eventuale risoluzione DNS degli endpoint .env)
# Anche se opensnitchd non è ancora partito, crasha o rimuove la sua regola NFQUEUE,
# nessun pacchetto NEW può uscire perché la policy della catena è DROP.
"${IPT}" -t mangle -P OUTPUT DROP
"${IPT}" -t mangle -A OUTPUT -o lo -j ACCEPT
"${IPT}" -t mangle -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Regola paracadute NFQUEUE (senza --queue-bypass) in fondo a mangle OUTPUT
if ! "${IPT}" -t mangle -A OUTPUT -m conntrack --ctstate NEW -j NFQUEUE --queue-num 0; then
    echo "[firewall] ERRORE CRITICO: impossibile creare regola NFQUEUE --queue-num 0."
    echo "[firewall] Assicurati che il modulo kernel 'nfnetlink_queue' / 'xt_NFQUEUE' sia caricato sull'host (es. sudo modprobe nfnetlink_queue xt_NFQUEUE)."
    exit 1
fi

echo "[firewall] Attesa avvio socket di opensnitch-ui (${SOCKET_PATH})..."
WAIT_COUNT=0
while [ ! -S "${SOCKET_PATH}" ] && [ "${WAIT_COUNT}" -lt 30 ]; do
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -S "${SOCKET_PATH}" ]; then
    echo "[firewall] Socket ${SOCKET_PATH} trovato! Connessione a opensnitch-ui pronta."
else
    echo "[firewall] ATTENZIONE: Socket ${SOCKET_PATH} non ancora presente dopo 15s, opensnitchd riproverà in background."
fi

echo "[firewall] Regole iptables attive (mangle OUTPUT):"
"${IPT}" -t mangle -L OUTPUT -n -v

echo "[firewall] Avvio opensnitchd..."
exec /usr/bin/opensnitchd \
    -rules-path "${RULES_DIR}" \
    -ui-socket "unix://${SOCKET_PATH}" \
    -process-monitor-method proc \
    -log-file /dev/stdout
