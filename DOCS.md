# 📖 Documentazione Completa — Agent-Box

Questa guida descrive nel dettaglio l'architettura, l'installazione, la configurazione e l'utilizzo quotidiano di **Agent-Box**, la sandbox containerizzata con firewall interattivo **OpenSnitch** per eseguire agenti di coding AI in sicurezza.

---

## 1. Architettura di Sicurezza (3 Container + 1 Opzionale)

Agent-Box separa completamente l'esecuzione dell'agente AI, il firewall di rete e l'interfaccia grafica di approvazione:

| Servizio (`docker-compose.yml`) | Container | Ruolo | Isolamento principale |
| :--- | :--- | :--- | :--- |
| `opensnitch-ui` | `agent-box-ui` | GUI Qt5/PyQt5 di OpenSnitch per approvare/negare le connessioni | `network_mode: "none"`, `cap_drop: ALL`, `read_only: true`, utente host `${PUID}:${PGID}` |
| `firewall` | `agent-box-firewall` | Demone `opensnitchd` + `iptables` Fail-Closed | `privileged: false`, sole capability `NET_ADMIN`, `NET_RAW`, `SYS_PTRACE`, `DAC_READ_SEARCH`, `DAC_OVERRIDE` |
| `agent` | `agent-box-sandbox` | Ambiente di lavoro con gli agenti AI | `network_mode: "service:firewall"`, `pid: "service:firewall"`, `cap_drop: ALL`, `no-new-privileges: true`, `read_only: true`, vede **solo** `/workspace` |
| `ollama` *(opzionale)* | `agent-box-ollama` | Server Ollama containerizzato (profilo `ollama`) | `cap_drop: ALL`, `no-new-privileges: true`, rete `agent_net` |

### Perché l'agente non può aggirare il firewall
- **Rete Fail-Closed**: `firewall/entrypoint.sh` imposta `POLICY DROP` sulla catena `mangle OUTPUT` (IPv4) e invia le nuove connessioni a `NFQUEUE --queue-num 0` **senza** `--queue-bypass`. Se `opensnitchd` non è attivo o viene terminato, tutto il traffico in uscita viene bloccato. IPv6 viene bloccato via `ip6tables` (se attivo sul kernel).
- **Socket UI isolato**: `./opensnitch/socket/osui.sock` è montato solo in `opensnitch-ui` e `firewall`, mai in `agent`. L'agente non può auto-approvare le proprie richieste.
- **Rootfs in sola lettura**: `agent` ha `read_only: true` e `CapEff = 0`. L'agente non può inviare `kill` ai processi `root` del container `firewall`.

---

## 2. Requisiti di Sistema

- **OS**: Linux (con supporto Wayland, XWayland o X11 per i popup di OpenSnitch).
- **Docker**: Docker Engine + Docker Compose v2 (`docker compose`).
  - L'utente corrente deve poter eseguire `docker` (appartenere al gruppo `docker` oppure usare `sudo`).
  - *Nota su Docker Rootless*: la modalità rootless rimappa gli UID nei namespace e può causare errori di permesso sui socket grafici in `/run/user/$UID`. È consigliato Docker Engine standard.
- **Kernel**: moduli `nfnetlink_queue`, `xt_NFQUEUE`, `xt_conntrack` (e `nf_tables` o `ip_tables` legacy; `firewall/entrypoint.sh` gestisce il fallback automatico su `iptables-legacy` e salta `ip6tables` se IPv6 è disabilitato).

---

## 3. Installazione e Primo Avvio

```bash
cd /percorso/di/agent-box
chmod +x agent-box.sh

# (Opzionale) Copia .env.example se vuoi personalizzare le variabili
cp -n .env.example .env

# 1. Costruisci le immagini per il tuo utente (PUID/PGID rilevati automaticamente)
./agent-box.sh build

# 2. Verifica il funzionamento del popup grafico di OpenSnitch
./agent-box.sh test-popup

# 3. Verifica tutte le misure di isolamento dentro la sandbox
./agent-box.sh test-isolation
```

Lo script `./agent-box.sh` rileva automaticamente ad ogni avvio:
- `PUID`, `PGID` e home reale dell'utente desktop (anche se invocato con `sudo`);
- `WAYLAND_DISPLAY`, `DISPLAY`, `XDG_RUNTIME_DIR` e file `.Xauthority` (GNOME/Mutter, KDE Plasma, wlroots/Sway/Hyprland, X11);
- Numero di core disponibili sull'host (`nproc`), limitando automaticamente `AGENT_CPUS` se superiore ai core fisici.

---

## 4. Riferimento Comandi (`./agent-box.sh`)

Sintassi generale:
```bash
./agent-box.sh [OPZIONI] <comando> [cartella_progetto] [argomenti...]
```

### Opzioni CLI globali
| Opzione | Descrizione |
| :--- | :--- |
| `-v`, `--volume HOST:CONTAINER[:ro\|rw]` | Monta un volume extra del progetto sul disco dentro `agent` (ripetibile più volte). |
| `--cpus <N\|all>` | Numero di core CPU da assegnare ad `agent` (default: `all`, tutti i core dell'host). |
| `--gpu <auto\|all\|igpu\|nvidia\|none>` | Configura l'accesso a iGPU (`/dev/dri`, `/dev/kfd`) e GPU NVIDIA (default: `auto`). |
| `--display <auto\|wayland\|xwayland\|x11\|none>` | Abilita le finestre grafiche X11, XWayland e Wayland per gli agenti AI e le applicazioni del progetto (default: `auto`). |
| `--no-gui` | Equivale a `--display none`. |
| `--audio <on\|off\|1\|0>` / `--no-audio` | Abilita o disabilita l'uscita audio (default: `on`). |
| `--mic [on\|off\|1\|0]` / `--no-mic` | Abilita o disabilita il microfono nel container (default: **disabilitato**, `0`). |
| `--fw-profile <profilo>` | Attiva uno dei profili di regole OpenSnitch presenti in `./opensnitch-profiles` (`interattivo`, `disabilitato`, `solo-lan`, `solo-lan-ia`, `solo-internet`, `solo-provider-ia`, `solo-443-ipv4`). |

Se `cartella_progetto` viene omessa (o il primo argomento non è una directory esistente, es. `./agent-box.sh claude --version`), viene montata automaticamente la cartella `./workspace`.
Quando esci da un agente specifico (`claude`, `codex`, `grok`, `agy`, `pi`, `gemini`, `opencode`, `aider`, `hermes`), **rimani automaticamente nella shell interattiva `bash` del container** in `/workspace` (digita `exit` per uscire dal container).

| Comando | Descrizione |
| :--- | :--- |
| `build` | Costruisce/ricostruisce le immagini Docker (`--build-arg PUID=... PGID=...`). Supporta argomenti extra di `docker compose build` (es. `--no-cache`). |
| `shell` / `sh` / `bash` | Avvia lo stack e apre una shell Bash interattiva dentro `/workspace`. |
| `claude` | Avvia **Claude Code** (`@anthropic-ai/claude-code`). |
| `chatgpt` / `codex` | Avvia **OpenAI Codex CLI** (`@openai/codex`). |
| `grok` | Avvia **xAI Grok CLI** (`@xai-official/grok`). |
| `agy` | Avvia **Google Antigravity CLI** (`agy`). |
| `pi` | Avvia **Pi Coding Agent** (`@mariozechner/pi-coding-agent`). |
| `gemini` | Avvia **Google Gemini CLI** (`@google/gemini-cli`). |
| `opencode` | Avvia **OpenCode** (`opencode-ai`). |
| `aider` | Avvia **Aider** (`aider-chat`, installato al primo avvio in `/home/agent/.local` tramite `uv`, oppure al build con `INSTALL_AIDER_AT_BUILD=1`). |
| `hermes` | Avvia **Hermes Agent** di Nous Research (`hermes-agent`, installato al primo avvio tramite `uv`, oppure al build con `INSTALL_HERMES_AT_BUILD=1`). |
| `claude-desktop` / `claude-gui` | Avvia **Claude Desktop** ufficiale per Linux (GUI Electron con supporto Claude Code, MCP e **GNOME Keyring** preconfigurato per la persistenza del login). |
| `chatgpt-desktop` / `chatgpt-gui` / `codex-desktop` / `codex-gui` | Avvia **ChatGPT / Codex Desktop App** ufficiale di OpenAI per Linux. |
| `opencode-desktop` / `opencode-gui` / `opencode-web` | Avvia **OpenCode Desktop** ufficiale per Linux (o l'interfaccia web `opencode web`). |
| `aider-desktop` / `aider-gui` | Avvia l'interfaccia grafica web di **Aider** (`aider --gui`) in una finestra desktop dedicata. |
| `grok-desktop` / `grok-gui` | Avvia **Grok** in una finestra desktop App-Mode dedicata (oppure `--terminal` per la finestra grafica CLI). |
| `gemini-desktop` / `gemini-gui` | Avvia **Gemini** in una finestra desktop App-Mode dedicata (oppure `--terminal` per la finestra grafica CLI). |
| `agy-desktop` / `agy-gui` / `antigravity-desktop` | Avvia **Antigravity (`agy`)** in una finestra grafica Alacritty dedicata (oppure `--web` per Project IDX). |
| `pi-desktop` / `pi-gui` | Avvia **Pi Coding Agent** in una finestra grafica Alacritty dedicata. |
| `hermes-desktop` / `hermes-gui` | Avvia **Hermes Agent** in una finestra grafica Alacritty dedicata. |
| `exec` | Esegue un comando arbitrario dentro il container `agent` (es. `./agent-box.sh exec /mio/progetto python3 script.py`). |
| `apt` / `apt-get` | Installa pacchetti `.deb` al volo in modalità rootless nel sysroot persistente `/home/agent/.local/sysroot` (funziona anche eseguendo `sudo apt install ...` o `apt install ...` direttamente dentro la shell del container). |
| `test-popup` / `popup` | Verifica il socket `osui.sock` ed esegue `curl -I https://example.com` dall'agente per far comparire il popup OpenSnitch. |
| `test-isolation` / `audit` | Esegue l'audit di sicurezza dentro `agent` (UID non-root, `CapEff=0`, `NoNewPrivs=1`, rootfs `read_only`, socket invisibile, `kill` bloccato). |
| `fw-profile [profilo\|list]` | Elenca o applica immediatamente un profilo di regole OpenSnitch da `./opensnitch-profiles` (riavviando `firewall` se già attivo). |
| `logs` | Mostra i log in tempo reale (`docker compose logs -f`). |
| `stop` / `down` | Arresta e rimuove i container e la rete (`docker compose down`). |

---

## 5. Configurazione (`.env` e `.agent-box.env` per-progetto)

Tutte le opzioni sono configurabili nel file `.env` globale (vedi `.env.example` come riferimento) oppure, anche dopo la creazione del progetto, in un file `.agent-box.env` posizionato direttamente dentro la cartella del progetto (`<cartella_progetto>/.agent-box.env`).
Ordine di priorità: **Opzioni CLI > `<cartella_progetto>/.agent-box.env` > variabili ambiente > `.env`**.

### Rete, Firewall, Risorse, GPU e GUI
| Variabile | Default | Descrizione |
| :--- | :--- | :--- |
| `WORKSPACE_DIR` | `./workspace` | Cartella di default montata su `/workspace` se non specificata da CLI. |
| `AGENT_EXTRA_VOLUMES` | *(vuoto)* | Lista di volumi extra del progetto sul disco (`host:container[:ro\|rw]`), separati da `,` o `;`. |
| `AUTO_DNS` | `1` | `1` consente automaticamente le query DNS (porta `53`), evitando il doppio popup in OpenSnitch; `0` richiede approvazione per ogni query DNS. |
| `AUTO_ALLOW_OLLAMA` | `0` | `1` pre-autorizza il traffico verso `OLLAMA_PORT` senza popup; `0` mostra anche le richieste a Ollama in OpenSnitch UI. |
| `OLLAMA_PORT` | `11434` | Porta usata dalla regola automatica `002-allow-ollama.json`. |
| `AGENT_MEM_LIMIT` | `8g` | Limite massimo di RAM per il container `agent`. |
| `AGENT_CPUS` | *(tutti)* | Core CPU per `agent`: vuoto, `0` o `all` usa tutti i core dell'host (`nproc`), altrimenti il numero specificato (limitato a `nproc`). |
| `AGENT_SHM_SIZE` | `512m` | Dimensione `/dev/shm` per `agent` (utile per applicazioni grafiche, browser ed Electron). |
| `AGENT_GPU` | `auto` | Accesso GPU/iGPU: `auto` (rileva `/dev/dri`, `/dev/kfd` e runtime NVIDIA), `all`, `igpu`, `nvidia`, `none`. |
| `AGENT_DISPLAY_MODE` | `auto` | Finestre grafiche **isolate** per agenti AI e app del progetto: `auto` usa **Wayland-only** su host Wayland (senza socket X11) oppure un server X11 annidato **Xephyr (`:99`)** su host X11, così gli screenshot dall'agente vedono **solo** le finestre del container e mai gli schermi dell'host. Valori: `auto`, `isolated`/`xephyr`, `wayland`, `x11-unsafe` (sconsigliato), `none`. |
| `AGENT_SCREEN_SIZE` | `1600x900` | Risoluzione iniziale della finestra sandbox isolata `Xephyr` (`:99`, ridimensionabile). |
| `AGENT_AUDIO` | `1` | `1` abilita l'uscita audio (altoparlanti/cuffie) tramite PulseAudio e ALSA; `0` disabilita tutto l'audio. |
| `AGENT_MIC` | `0` | **Microfono disabilitato di default (`0`)**: il socket PulseAudio/PipeWire dell'host e i device di cattura ALSA (`/dev/snd/pcmC*D*c`) non vengono montati in `agent` (l'audio in uscita passa da un canale FIFO PCM unidirezionale). Imposta a `1` (o `--mic`) per abilitare il microfono. |
| `OPENSNITCH_SHOW_MAIN_WINDOW` | `1` | `1` apre automaticamente la finestra principale di OpenSnitch all'avvio; `0` avvia OpenSnitch ridotto nella system tray. |
| `OPENSNITCH_PROFILE` | *(vuoto)* | Profilo regole OpenSnitch preimpostato (`interattivo`, `disabilitato`, `solo-lan`, `solo-lan-ia`, `solo-internet`, `solo-provider-ia`, `solo-443-ipv4`). |

### Profili di Regole OpenSnitch (`./opensnitch-profiles`)
Tutti i profili sono salvati in `./opensnitch-profiles/<profilo>/*.json` e sono montati anche dentro il container `opensnitch-ui` in `/home/snitch/opensnitch-profiles` (così puoi importarli direttamente dalla finestra principale di OpenSnitch tramite **Azioni -> Importa regole** selezionando la cartella del profilo, oppure da CLI con `./agent-box.sh fw-profile <profilo>`):

| Cartella Profilo | Alias CLI / `.env` | Comportamento |
| :--- | :--- | :--- |
| `0-interattivo-default` | `interattivo` | Consente loopback e DNS, chiede conferma tramite popup per ogni altra connessione. |
| `1-disabilitato-allow-all` | `disabilitato` | Equivalente a firewall disabilitato: consente tutto il traffico senza popup. |
| `2-solo-lan` | `solo-lan` | Consente solo le reti locali/private (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`) e blocca Internet. |
| `3-solo-lan-con-provider-ia` | `solo-lan-ia` | Consente le reti LAN private e i domini/API dei provider IA, bloccando tutto il resto di Internet. |
| `4-solo-internet-no-lan` | `solo-internet` | Blocca tutte le reti LAN private e consente Internet pubblica. |
| `5-solo-provider-ia` | `solo-provider-ia` | Blocca tutte le reti LAN private e tutto il resto di Internet, consentendo solo i domini/API dei provider IA. |
| `6-solo-443-ipv4` | `solo-443-ipv4` | Consente esclusivamente traffico sulla porta `443` verso indirizzi IPv4 (più DNS/loopback), bloccando ogni altra porta. |

### Modelli Locali e TLS Self-Signed
| Variabile | Default | Descrizione |
| :--- | :--- | :--- |
| `OLLAMA_HOST` | `http://host.docker.internal:11434` | URL del server Ollama (sull'host o nel container `ollama`). |
| `OLLAMA_API_BASE` | `http://host.docker.internal:11434` | Base URL Ollama usato da tool Python/LiteLLM (es. Aider). |
| `LOCAL_LLM_BASE_URL` | *(vuoto)* | Endpoint OpenAI-compatibile locale (es. `https://192.168.1.50:8443/v1` per LM Studio, vLLM, llama.cpp, LocalAI). |
| `LOCAL_LLM_API_KEY` | `local` | Chiave API o token per l'endpoint locale. |
| `LOCAL_LLM_MODEL` | `qwen2.5-coder:latest` | ID del modello da preconfigurare nei profili locali. |
| `LOCAL_LLM_NAME` | `Local LLM` | Nome visualizzato del provider locale. |
| `AGENT_REGENERATE_LOCAL_CONFIG` | `0` | Imposta a `1` per rigenerare ad ogni avvio i file `opencode.json`, `models.json` (Pi) e `config.toml` (Codex) nel volume persistente `agent_home`. |
| `AGENT_TLS_INSECURE` | `0` | Imposta a `1` **solo su reti fidate** per disabilitare la verifica TLS in Node.js (`NODE_TLS_REJECT_UNAUTHORIZED=0`) con certificati self-signed senza CA in `./certs`. |

### API Key Cloud (opzionali)
- `ANTHROPIC_API_KEY` (Claude Code)
- `OPENAI_API_KEY`, `OPENAI_BASE_URL` (ChatGPT / Codex CLI)
- `XAI_API_KEY` (Grok CLI)
- `GEMINI_API_KEY` (Gemini CLI)
- `OPENROUTER_API_KEY` (OpenRouter per OpenCode / Pi / Aider)

*Nota*: molti CLI (`claude`, `codex`, `grok`, `agy`, `gemini`) supportano anche il login interattivo tramite browser/link, le cui credenziali restano salvate nel volume persistente `agent_home` (`/home/agent`).

---

## 6. Modelli Locali e Certificati HTTPS Self-Signed

### Configurazione automatica dei client
Quando `OLLAMA_HOST` o `LOCAL_LLM_BASE_URL` sono definiti in `.env`, `agent/entrypoint.sh` crea automaticamente (se non già presenti, o se `AGENT_REGENERATE_LOCAL_CONFIG=1`):
- `~/.config/opencode/opencode.json` (provider `ollama` e `local`)
- `~/.pi/agent/models.json` (provider `ollama` e `local` per `pi`)
- `~/.codex/config.toml` (profilo `local` utilizzabile con `./agent-box.sh chatgpt --profile local`)

### Usare endpoint HTTPS con certificato self-signed (metodo consigliato)
Poiché il container `agent` ha il root filesystem in sola lettura (`read_only: true`), non è possibile modificare `/etc/ssl/certs`. Per rendere attendibile una CA locale o un certificato self-signed:
1. Copia i file `.crt` o `.pem` nella cartella `./certs/` nella root del progetto.
2. Riavvia lo stack (`./agent-box.sh stop && ./agent-box.sh shell`).
3. `agent/entrypoint.sh` unisce automaticamente i certificati di sistema con quelli presenti in `./certs/` dentro `/tmp/ca-certificates.crt` ed esporta `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` e `NODE_EXTRA_CA_CERTS`.

### Avviare Ollama come container opzionale
Se non hai Ollama installato sull'host, puoi avviare il servizio incluso nel Compose:
```bash
docker compose --profile ollama up -d ollama
```
E impostare in `.env`:
```ini
OLLAMA_HOST=http://ollama:11434
OLLAMA_API_BASE=http://ollama:11434
```

---

## 7. File `/etc/hosts` Modificabile (`./hosts`)

Il file `./hosts` nella directory del progetto viene creato automaticamente al primo avvio e montato in scrittura (`rw`) su `/etc/hosts` dentro `agent`:
- Puoi aggiungere hostname locali dall'host modificando `./hosts` (es. `192.168.1.50 llm.locale`).
- Anche i processi dentro `agent` possono appendere/modificare `/etc/hosts` direttamente.
  - *Nota*: poiché `/etc` resta in sola lettura, comandi come `sed -i /etc/hosts` falliscono (tentano di creare un file temporaneo in `/etc`); usa scrittura diretta (`echo "..." >> /etc/hosts` oppure modifica `./hosts` dall'host).
- `agent-box.sh` aggiunge automaticamente l'IP del gateway Docker per `host.docker.internal` se non è già presente in `./hosts`.

---

## 8. Persistenza dei Dati (Tutto Interno alla Cartella del Progetto)

Il progetto è completamente autonomo e non crea volumi Docker esterni sul sistema operativo:

| Percorso | Scopo |
| :--- | :--- |
| `./workspace` (o `[cartella_progetto]`) | Directory del progetto montata in `/workspace` (più eventuali volumi extra via `-v` / `AGENT_EXTRA_VOLUMES`). |
| `./agent-home` | `/home/agent`: conserva configurazioni, login, portachiavi **GNOME Keyring** (`~/.local/share/keyrings`), cache `cargo`/`npm`/`uv` e installazioni locali di `aider` e `hermes`. |
| `./ollama-data` | `/root/.ollama`: modelli del servizio opzionale `ollama`. |
| `./opensnitch/rules` | Regole permanenti di OpenSnitch (`000-allow-loopback.json`, `001-auto-dns.json`, ecc.). |
| `./opensnitch/ui-config` | Preferenze della GUI di OpenSnitch. |
| `./certs` | Certificati CA personalizzati/self-signed (montati `:ro` in `agent`). |
| `./hosts` | File `/etc/hosts` condiviso e modificabile (montato `:rw` in `agent`). |
| `./.runtime` | File generati dinamicamente a runtime (`docker-compose.override.yml`, `.Xauthority` isolato per `agent`). |

---

## 9. Risoluzione Problemi (Troubleshooting)

- **Il popup di OpenSnitch non appare sul desktop**:
  - Controlla i log di `opensnitch-ui`: `docker compose logs --tail=50 opensnitch-ui`.
  - Verifica che il socket esista: `ls -la ./opensnitch/socket/osui.sock`.
  - Su sessioni X11/XWayland, `ui/entrypoint.sh` normalizza automaticamente `.Xauthority` con `xauth` (`FamilyWild`); assicurati di lanciare `./agent-box.sh` dalla stessa sessione utente desktop (o con `sudo` preservando la sessione).
- **Errore `firewall` all'avvio**:
  - Controlla `docker compose logs --tail=50 firewall`.
  - Verifica che sul kernel host siano disponibili i moduli `nfnetlink_queue` e `xt_NFQUEUE` (`sudo modprobe nfnetlink_queue xt_NFQUEUE`).
- **Pre-installare `aider` o `hermes` al build invece che al primo avvio**:
  ```bash
  docker compose build \
    --build-arg PUID="$(id -u)" \
    --build-arg PGID="$(id -g)" \
    --build-arg INSTALL_AIDER_AT_BUILD=1 \
    --build-arg INSTALL_HERMES_AT_BUILD=1 \
    agent
  ```
- **Cambio utente / PC**:
  - `agent-box.sh` controlla l'etichetta `agentbox.uid` sulle immagini e ricostruisce automaticamente se cambia l'UID dell'utente corrente. Per forzare un rebuild completo: `./agent-box.sh build --no-cache`.
