#!/bin/sh
set -eu

RULES_DIR="/etc/opensnitchd/rules"
SOCKET_DIR="/run/opensnitch"
SOCKET_PATH="${SOCKET_DIR}/osui.sock"
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

# MANGLE OUTPUT: Policy di default DROP (Fail-Closed!)
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

# 3. Regola permanente OpenSnitch per traffico loopback (127.0.0.1)
cat <<'EOF' > "${RULES_DIR}/000-allow-loopback.json"
{
  "created": "2026-01-01T00:00:00Z",
  "updated": "2026-01-01T00:00:00Z",
  "name": "000-allow-loopback",
  "enabled": true,
  "precedence": true,
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
    cat <<'EOF' > "${RULES_DIR}/001-auto-dns.json"
{
  "created": "2026-01-01T00:00:00Z",
  "updated": "2026-01-01T00:00:00Z",
  "name": "001-auto-dns",
  "enabled": true,
  "precedence": true,
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

# 5. Gestione AUTO_ALLOW_OLLAMA (opzionale per consentire chiamate a Ollama locale senza popup)
if [ "${AUTO_ALLOW_OLLAMA:-0}" = "1" ]; then
    OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    echo "[firewall] AUTO_ALLOW_OLLAMA=1 attivo: consentito traffico verso porta ${OLLAMA_PORT}."
    cat <<EOF > "${RULES_DIR}/002-allow-ollama.json"
{
  "created": "2026-01-01T00:00:00Z",
  "updated": "2026-01-01T00:00:00Z",
  "name": "002-allow-ollama",
  "enabled": true,
  "precedence": true,
  "action": "allow",
  "duration": "always",
  "operator": {
    "type": "simple",
    "operand": "dest.port",
    "data": "${OLLAMA_PORT}",
    "sensitive": false
  }
}
EOF
else
    rm -f "${RULES_DIR}/002-allow-ollama.json"
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
