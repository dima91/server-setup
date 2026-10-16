# Server setup

## Portainer prerequisites

Prima di avviare lo stack è necessario configurare i record DNS presso il proprio provider (OVH):

### Record A (root domain)

| Nome | Tipo | Valore |
|------|------|--------|
| `example.com` | **A** | `<IP del server>` |

### Record CNAME wildcard (fondamentale)

```
CNAME *.example.com → example.com.
```

> ⚠️ **Attenzione:** Il CNAME wildcard indirizza qualunque sottodominio (`portainer.example.com`, `app.example.com`, ecc.) alla zona principale. Su OVH, se la zona radice è un record A, il CNAME wildcard è supportato. In caso di problemi, creare singoli record **A** per ogni servizio:
>
> | Nome | Tipo | Valore |
> |------|------|--------|
> | `portainer` | **A** | `<IP del server>` |
> | `app` | **A** | `<IP del server>` |

---



## Locale vs Server

Lo stack usa la stessa codebase (`docker-compose.yml`) sia in locale che sul server: quello che cambia è solo il file `.env` passato a Compose, tramite [Docker Compose profiles](https://docs.docker.com/compose/how-tos/profiles/).

**Locale** (nessuna modifica necessaria, certificato NPM self-signed, VPN/CrowdSec/Bouncer spenti):

```bash
cd services
docker compose --env-file .env.local up -d
```

I servizi con dominio (NPM, Portainer via proxy) sono raggiungibili su `*.127.0.0.1.nip.io` (wildcard DNS pubblico che risolve a `127.0.0.1`).

Attenzione: `--profile` da riga di comando **sostituisce** `COMPOSE_PROFILES` del file env. Se avvii altri profili a mano (es. `--profile server`), passa gli stessi `--profile` anche a `down`, altrimenti i servizi degli altri profili restano in esecuzione.

**Server** (stack completo, certificati Let's Encrypt reali):

```bash
cd services
cp example.env .env   # solo la prima volta: personalizzare dominio/credenziali
docker compose up -d  # legge .env di default, con COMPOSE_PROFILES=server
```

`setup.sh` (vedi sotto) automatizza anche questo passaggio.

`services/.env` (con le credenziali reali del server) non è versionato: usare `services/example.env` come riferimento. `services/.env.local` invece è versionato con valori fittizi pensati solo per lo sviluppo in locale.

## Usage

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/dima91/server-setup.git
cd server-setup
sudo bash setup.sh <new_user> <new_user_passw> <ssh_port>
```

## Setup.sh

Il file `setup.sh` è uno script Bash pensato per automatizzare la configurazione iniziale di un server (tipicamente una VPS o un server dedicato) con sistema Debian/Ubuntu. Lo script viene eseguito in più fasi (stage), riavviando la macchina tra una fase e l’altra per applicare modifiche a basso livello (es. cambio di porta SSH, rimozione dell’utente predefinito). Ecco una descrizione dettagliata delle operazioni effettuate, fase per fase.

### Panoramica

- Lo script deve essere eseguito come **root**.
- Accetta tre parametri: `<new_user>`, `<new_user_passw>`, `<ssh_port>`.
- Durante la prima esecuzione crea una cartella persistente `/etc/server_setup`, vi copia l’intero script e genera un file `setup_info` che tiene traccia dei parametri e dello stage corrente.
- Al termine di ogni stage viene aggiornato il file `setup_info` e viene riavviato il sistema. Dopo il reboot, l’utente indicato (prima l’old user, poi il nuovo) deve rilanciare lo script `setup.sh` per proseguire.

---

### Stage 0 – Preparazione (primo avvio)

- **Verifica** che lo script sia eseguito come root.
- **Controlla** che la cartella `/etc/server_setup` non esista già (altrimenti salta questa fase e procede con lo stage successivo).
- **Acquisisce**:
    - OLD_USER = utente che ha lanciato `sudo` (o `$USER` se non usato sudo).
    - NEW_USER, NEW_USER_PASSW, NEW_SSH_PORT dai parametri.
    - I gruppi primari e secondari dell’utente corrente.
- **Chiede conferma** all’utente mostrando tutti i valori.
- **Crea** la cartella `SETUP_DATA_FOLDER` (`/etc/server_setup`), vi copia l’intera directory contenente lo script, ne imposta i permessi e crea un symlink in `/usr/local/bin/setup.sh`.
- **Scrive** il file `setup_info` con tutti i dati e `NEXT_STAGE=1`. Il file contiene la password in chiaro e viene riletto con `source` da root a ogni stage: i valori sono quotati (`printf %q`, nessun carattere speciale viene interpretato) e il file è leggibile solo da root (`0600`).
- **Riavvia** il sistema.

---

### Stage 1 – Aggiornamenti, pacchetti base e creazione nuovo utente

- **Esegue** `apt update && apt upgrade`.
- **Installa** i pacchetti essenziali elencati in `ESSENTIAL_PACKAGES` (strumenti come build-essential, curl, git, ufw, htop, net-tools, ecc.).
- **Crea** il nuovo utente `NEW_USER`, gli assegna gli stessi gruppi (aggiungendo `sudo`), imposta la password e aggiunge l’alias `updg` nel file `.bash_aliases`.
- **Crea un file di swap** eseguendo lo script `make_swap.sh` (dettagli non mostrati, presumibilmente configura un file di swap di dimensioni adeguate).
- **Aggiorna** il file `setup_info` con `NEXT_STAGE=2`.
- **Riavvia** il sistema.

---

### Stage 2 – Rimozione vecchio utente, SSH, UFW e installazione Docker

- **Rimuove** completamente l’utente originale `OLD_USER` (utente di default di molte VPS, es. `debian`).
- **Modifica la porta SSH** nel file `/etc/ssh/sshd_config` impostandola a `NEW_SSH_PORT`. Disabilita anche il login di root via SSH.
- **Riavvia** il servizio `sshd`.
- **Configura UFW**:
    - Abilita IPv6.
    - Imposta policy: deny in ingresso, allow in uscita.
    - Apre la nuova porta SSH.
    - Attiva UFW (`ufw enable`: `systemctl enable` da solo non basta, `/etc/ufw/ufw.conf` parte con `ENABLED=no`) e lo abilita all'avvio. La sessione SSH in corso non cade: la porta è già aperta.
- **Installa Docker**:
    - Rileva la distribuzione (Debian/Ubuntu) tramite `hostnamectl`.
    - Rimuove gli eventuali vecchi pacchetti Docker/containerd/runc in conflitto (solo quelli installati, senza conferma interattiva).
    - Aggiunge la repository ufficiale Docker.
    - Installa `docker-ce`, `docker-ce-cli`, `containerd.io` e i plugin necessari.
    - Aggiunge il nuovo utente al gruppo `docker`.
- **Aggiorna** il file `setup_info` con `NEXT_STAGE=3`.
- **Riavvia** il sistema.

---

### Stage 3 – Servizi Docker (NPM, CrowdSec, Portainer, ecc.)

- **Ferma e disabilita** Apache (se installato) per liberare le porte 80/443.
- **Apre le porte firewall** necessarie: 80, 443, 1195 (VPN personale). Portainer non ha una porta propria: si raggiunge da `portainer.<dominio>` tramite NPM. L'admin di NPM (81) e Open WebUI (3000) sono pubblicate **solo su localhost**: da fuori Open WebUI si raggiunge da `webui.<dominio>` (con TLS e controllo CrowdSec), l'admin di NPM con un tunnel SSH (`ssh -L 8081:127.0.0.1:81 -p <porta> <utente>@<server>`, poi `http://127.0.0.1:8081`).
- **Copia** la cartella `services` nella home del nuovo utente (se esiste già la riusa: modifica lì il `.env`) e la intesta al nuovo utente; il `.env`, con le credenziali, è `0600`.
- **Si posiziona** nella directory `services` e:
    - Verifica che `.env` esista (altrimenti si ferma: copia `example.env` in `.env` e rilancia). Il file non viene "sourced": è la sintassi di Compose, non quella della shell.
    - Genera una password casuale per il database di NPM e la inserisce nel file `.env` al posto del segnaposto `NPM_DB_PASSWORD=change_me_npm_db_password` (o `npm_db_password`); una password già scelta a mano non viene toccata.
- **Crea la rete docker `proxynet`** se non esiste (nel compose è `external`).
- **Avvia** tutti i container con `docker compose up -d`. Se fallisce lo stage si ferma, senza avanzare.
- **Attende** 200 secondi (con log intermedi ogni 20s) per dare il tempo ai servizi di inizializzarsi.
- **Se il profilo `server` è attivo** (CrowdSec tra i servizi di Compose; altrimenti salta tutto questo):
    - Attende che CrowdSec sia davvero pronto: `cscli lapi status`, fino a 24 tentativi (`cscli version` risponde subito, prima che la LAPI sia su).
    - Genera la chiave API del bouncer con `cscli bouncers add npm-bouncer` (se il bouncer esiste già da un tentativo precedente lo ricrea) e la scrive in `.env` (`CROWDSEC_BOUNCER_API_KEY`).
    - Ricrea il container `cs-bouncer` per applicare la nuova chiave e verifica che risponda `200` al ForwardAuth.
    - Solo a questo punto imposta `CROWDSEC_FORWARD_AUTH_URL` in `.env` e ricrea `npm-init`, che attiva il controllo su tutti i proxy host. Fino ad allora i proxy host sono raggiungibili senza controllo, ma non c'è nessuna finestra in cui rispondano 403/500: vedi [CrowdSec e NPM](#crowdsec-e-npm).
    - Se uno di questi passaggi fallisce lo stage si ferma con un errore **senza avanzare** (`NEXT_STAGE` resta 3): risolto il problema basta rilanciare `setup.sh`.
- **Aggiorna** il file `setup_info` con `NEXT_STAGE=4`.
- **Riavvia** il sistema.

---

### Stage 4 – Completamento

- La fase successiva (NEXT_STAGE diverso da 1,2,3) stampa semplicemente “Setup is finished. System ready!” e termina, perché tutto è stato configurato.

### Altre funzioni di supporto

- `log()`: scrive messaggi con timestamp su file `/var/log/setup.log` e su console.
- `update_info_file()`: riscrive il file `setup_info` con i parametri attuali e il prossimo stage.

### Riepilogo dei risultati finali

Una volta completato lo script, il server avrà:

- Un nuovo utente con permessi sudo e gruppi ereditati dall’utente originale.
- Accesso SSH su una porta personalizzata (e root disabilitato).
- Firewall UFW attivo con sole porte necessarie aperte (SSH, 80, 443, 1195).
- Swap configurato.
- Docker installato e utente aggiunto al gruppo docker.
- Stack di servizi in esecuzione: Nginx Proxy Manager, CrowdSec, un CS bouncer per NPM, un database per NPM, probabilmente Portainer, un server VPN e Open WebUI (a giudicare dalle porte aperte).
- Integrazione automatica tra CrowdSec e NPM tramite la chiave bouncer generata.

Lo script è pensato per essere eseguito una sola volta e gestisce i riavvii in modo trasparente, richiedendo all’utente di rilanciare il comando `setup.sh` dopo ogni reboot.

## DNS prerequisites

Prima di procedere con il setup manuale o automatico, assicurarsi che i record DNS siano configurati correttamente.

| Record | Nome | Tipo | Target |
|--------|------|------|--------|
| Root | `example.com` | **A** | `<IP del server>` |
| Wildcard | `*.example.com` | **CNAME** | `example.com.` |

Il CNAME wildcard è **obbligatorio** per far funzionare tutti i sottodomini (Portainer, App, ecc.) senza dover creare un record A per ciascuno.

> **Nota per OVH:** Se la zona DNS non accetta un CNAME sulla radice, creare record **A** espliciti per ogni servizio:
>
> | Nome | Tipo | Valore |
> |------|------|--------|
> | `portainer` | **A** | `<IP del server>` |
> | `app` | **A** | `<IP del server>` |

## Manual setup

1. **Configurare i record DNS** (vedi sezione "DNS prerequisites" sopra)
2. Create NPM certificates:
    - `certbot certonly --config /etc/letsencrypt.ini --work-dir /tmp/letsencrypt-lib --logs-dir /data/logs --cert-name ${CERTIFICATE_NAME} --agree-tos --authenticator webroot -m ${ADMIN_EMAIL} --preferred-challenges http --domains ${FULL_DOMAIN} --key-type ecdsa`
3. Add NPM hosts via NPM UI

## CrowdSec e NPM

Con il profilo `server` CrowdSec e il bouncer sono collegati a NPM in due punti:

- **Rilevamento**: CrowdSec legge i log di NPM (`/var/log/nginx/logs/proxy-host-*.log`, volume `npm_data` in sola lettura) grazie a [`services/crowdsec/acquis.yaml`](services/crowdsec/acquis.yaml), montato in `/etc/crowdsec/acquis.yaml`. L'etichetta `type: nginx-proxy-manager` è quella su cui filtra il parser della collection.
- **Blocco**: se `CROWDSEC_FORWARD_AUTH_URL` è valorizzata in `.env`, `npm-init` scrive in `/data/nginx/custom/server_proxy.conf` (volume `npm_data`, montato in lettura/scrittura in `npm-init`) un blocco con un `auth_request` verso `cs-bouncer`. NPM include quel file in **ogni** proxy host, anche quelli creati dalla UI e non presenti nel descriptor: gli IP con una decisione di ban ricevono 403. Il blocco è delimitato da marcatori e il resto del file non viene toccato; se la variabile è vuota il blocco viene rimosso.

Il blocco è *fail-closed*: con una chiave bouncer non valida, o con `cs-bouncer` fermo o assente, i proxy host rispondono 403/500. Per questo `CROWDSEC_FORWARD_AUTH_URL` in `example.env` è **vuota**: la imposta `setup.sh` (stage 3) dopo aver generato la chiave e verificato che il bouncer risponda, e solo se il profilo `server` è attivo. Se la imposti a mano, il profilo `server` deve essere attivo; se lo togli da `COMPOSE_PROFILES` svuota anche la variabile. In locale (`.env.local`) non è definita e non cambia nulla.

Su un server già installato prima di questa modifica, dopo aver aggiornato il repo:

```bash
cd services
docker compose up -d                  # ricrea npm e open-webui con le porte 81 e 3000 solo su localhost, e npm-init con il nuovo volume
docker compose up -d npm-init         # riallinea gli host e scrive il blocco globale (se la variabile è già in .env)
```

`npm-init` prima allinea gli host del descriptor (l'`advanced_config` del vecchio snippet per-host sparisce) e solo dopo scrive il blocco globale, poi fa ricaricare nginx. Se `CROWDSEC_FORWARD_AUTH_URL` non è ancora in `.env`, aggiungi `CROWDSEC_FORWARD_AUTH_URL=http://cs-bouncer:8080/api/v1/forwardAuth` solo dopo aver verificato che il bouncer risponda: `docker exec npm curl -s -o /dev/null -w '%{http_code}' http://cs-bouncer:8080/api/v1/forwardAuth` deve stampare `200` (403 = chiave non valida).

## Crowdsec utils

```bash
docker exec crowdsec cscli alerts list      # IP bannati
docker exec crowdsec cscli decisions list   # decisioni attive
docker exec crowdsec cscli metrics          # statistiche
```

# Endpoints

