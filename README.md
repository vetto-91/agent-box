# 🔒 Agent-Box (Hardened 3-Container Edition — Ubuntu 26.04)

Implementazione Docker Compose ispirata al progetto **agent-box** di Morrolinux ([video di riferimento](https://www.youtube.com/watch?v=vaLkNVDxNP8)), riprogettata su **Ubuntu 26.04 LTS** con **un'architettura a 3 container non privilegiati**, completamente autonoma nella cartella del progetto, rilevamento automatico dell'utente corrente, supporto **iGPU/GPU** e finestre grafiche **Wayland / XWayland / X11** sia per OpenSnitch che per gli agenti AI e le applicazioni del progetto.

> 📖 Per la guida completa su tutti gli agenti supportati, opzioni CLI (`-v`, `--cpus`, `--gpu`, `--display`), modelli locali, certificati HTTPS self-signed, `/etc/hosts` e troubleshooting, consulta **[DOCS.md](DOCS.md)**.

---

## 🏗️ Architettura di Sicurezza (3 Container)

```
┌─────────────────────────────────────────────────────────────────────────┐
│ HOST LINUX (Wayland / XWayland)                                         │
│                                                                         │
│  ┌──────────────────────────┐         ┌──────────────────────────────┐  │
│  │ 1. opensnitch-ui         │         │ 2. firewall (opensnitchd)    │  │
│  │ - Utente host auto-rilev.│ Socket  │ - privileged: false          │  │
│  │ - cap_drop: ALL          │◄───────►│ - CAP_NET_ADMIN / RAW        │  │
│  │ - network_mode: "none"   │  Unix   │ - iptables Fail-Closed (DROP)│  │
│  │ - Wayland nativo + XCB   │         └──────────────▲───────────────┘  │
│  └──────────────────────────┘                        │                  │
│                                       Condivide solo │ network + PID ns │
│                                                      ▼                  │
│                                       ┌──────────────────────────────┐  │
│                                       │ 3. agent (Sandbox AI)        │  │
│                                       │ - Utente host auto-rilevato  │  │
│                                       │ - privileged: false          │  │
│                                       │ - cap_drop: ALL (CapEff = 0) │  │
│                                       │ - no-new-privileges: true    │  │
│                                       │ - read_only: true (rootfs)   │  │
│                                       │ - Vede SOLO /workspace       │  │
│                                       └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Avvio Rapido

Non è necessario configurare manualmente `PUID`, `PGID`, `WAYLAND_DISPLAY` o `XDG_RUNTIME_DIR`: lo script `./agent-box.sh` rileva automaticamente l'utente corrente (anche se invocato tramite `sudo`), il socket Wayland (`/run/user/<UID>/wayland-*`), il bus DBus e il cookie XWayland, e ricostruisce automaticamente le immagini se l'UID cambia.

### 1. Avviare e testare il popup di OpenSnitch su Wayland
```bash
cd ~/agent-box
chmod +x agent-box.sh

# Verifica la connessione tra opensnitchd e opensnitch-ui e fa apparire un popup di prova:
./agent-box.sh test-popup
```

### 2. Avviare una sessione isolata su una cartella di progetto
Quando esci da un agente specifico (`claude`, `codex`, `opencode`, ecc.), **rimani automaticamente nella shell interattiva del container** in `/workspace` (digita `exit` per uscire dal container).

```bash
# Apre una shell bash isolata montando /percorso/mio-progetto in /workspace
./agent-box.sh shell /percorso/mio-progetto

# Oppure avvia direttamente uno degli agenti preinstallati:
./agent-box.sh claude /percorso/mio-progetto
./agent-box.sh chatgpt /percorso/mio-progetto   # OpenAI Codex CLI (alias: codex)
./agent-box.sh grok /percorso/mio-progetto      # xAI Grok CLI
./agent-box.sh agy /percorso/mio-progetto       # Google Antigravity CLI
./agent-box.sh pi /percorso/mio-progetto        # Pi Coding Agent
./agent-box.sh gemini /percorso/mio-progetto    # Google Gemini CLI
./agent-box.sh opencode /percorso/mio-progetto
./agent-box.sh aider /percorso/mio-progetto
./agent-box.sh hermes /percorso/mio-progetto    # Hermes Agent (Nous Research)

# Opzioni avanzate (volumi extra sul disco, core CPU, iGPU/GPU, display X11/Wayland):
./agent-box.sh -v /percorso/dati:/dati:ro --cpus 4 --gpu auto --display auto claude /percorso/mio-progetto

# Oppure esegui qualsiasi altro comando nella sandbox:
./agent-box.sh exec /percorso/mio-progetto <comando>
```

### 3. Modelli locali e HTTPS con certificato self-signed
1. **Certificati CA self-signed**: copia i file `.crt` o `.pem` della tua CA locale nella cartella `./certs/`. All'avvio, `agent` li unisce automaticamente al bundle CA in `/tmp/ca-certificates.crt` (compatibile con `read_only: true`) ed esporta `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` e `NODE_EXTRA_CA_CERTS`.
   - In alternativa, solo per test rapidi su reti fidate, puoi impostare `AGENT_TLS_INSECURE=1` in `.env`.
2. **Endpoint locale OpenAI-compatibile** (LM Studio, vLLM, llama.cpp, Ollama su HTTPS, ecc.): imposta in `.env`:
   - `LOCAL_LLM_BASE_URL=https://192.168.1.50:8443/v1`
   - `LOCAL_LLM_MODEL=qwen2.5-coder:32b`
   - `LOCAL_LLM_API_KEY=local` (opzionale)
   Verranno configurati automaticamente `~/.config/opencode/opencode.json`, `~/.pi/agent/models.json` e il profilo `local` di `~/.codex/config.toml` (`codex --profile local`).

3. **`/etc/hosts` modificabile**: il file `./hosts` (creato automaticamente al primo avvio) è montato su `/etc/hosts` in scrittura dentro `agent`, quindi puoi aggiungere hostname locali personalizzati sia dall'host (`./hosts`) sia da dentro la sandbox (`/etc/hosts`), mantenendo comunque la risoluzione di `host.docker.internal`.

### 4. Verificare l'isolamento con l'audit automatico
```bash
./agent-box.sh test-isolation
```

---

## ⚙️ Variabili di Configurazione (`.env`)

| Variabile | Default | Descrizione |
| :--- | :--- | :--- |
| `AUTO_DNS` | `1` | Se `1`, consente automaticamente le query DNS (porta 53) evitando il doppio popup in OpenSnitch (il traffico HTTP/HTTPS/TCP effettivo richiede sempre approvazione). Imposta a `0` per approvare anche ogni singola query DNS. |
| `AUTO_ALLOW_OLLAMA` | `0` | Se `1`, pre-autorizza il traffico verso la porta `11434` (Ollama) senza popup. Se `0`, anche le chiamate a Ollama vengono mostrate da OpenSnitch UI. |
| `OLLAMA_HOST` | `http://host.docker.internal:11434` | Indirizzo del server Ollama (sull'host o nel container opzionale). |
| `AGENT_CPUS` | *(tutti)* | Core CPU assegnati al container `agent` (vuoto, `0` o `all` = tutti i core dell'host). |
| `AGENT_EXTRA_VOLUMES` | *(vuoto)* | Volumi extra del progetto sul disco (`host:container[:ro\|rw]`, separati da `,` o `;`). Configurabile anche in `<cartella_progetto>/.agent-box.env`. |
| `AGENT_GPU` | `auto` | Accesso iGPU (`/dev/dri`, `/dev/kfd`) e GPU NVIDIA (`auto`, `all`, `igpu`, `nvidia`, `none`). |
| `AGENT_DISPLAY_MODE` | `auto` | Finestre grafiche Wayland / XWayland / X11 per agenti e app del progetto (`auto`, `wayland`, `xwayland`, `x11`, `none`). |
| `OPENSNITCH_SHOW_MAIN_WINDOW` | `1` | Apre di default la finestra principale di OpenSnitch all'avvio (`0` per lasciarla solo nella system tray). |
