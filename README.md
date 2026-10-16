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
    - I gruppi secondari dell’utente originale (`id -Gn <OLD_USER>`, escluso il gruppo primario, confrontato per nome intero: un gruppo `dev-ops` non viene toccato se il primario è `dev`).
- **Chiede conferma** all’utente mostrando tutti i valori.
- **Crea** la cartella `SETUP_DATA_FOLDER` (`/etc/server_setup`) con modo `0700` (solo root: la copia del repo può contenere `services/.env` con le credenziali e resta lì fino allo stage 4), vi copia l’intera directory contenente lo script, ne imposta i permessi e crea un symlink in `/usr/local/bin/setup.sh`. Con un numero di parametri sbagliato si ferma prima di creare qualsiasi cosa.
- **Scrive** il file `setup_info` con tutti i dati e `NEXT_STAGE=1`. Il file contiene la password in chiaro e viene riletto con `source` da root a ogni stage: i valori sono quotati (`printf %q`, nessun carattere speciale viene interpretato) e il file è leggibile solo da root (`0600`). La scrittura è atomica (file temporaneo + `mv`): se si interrompe, il file di stato precedente resta intatto e lo stage si ferma con un errore.
- **Riavvia** il sistema.

---

### Stage 1 – Aggiornamenti, pacchetti base e creazione nuovo utente

- **Esegue** `apt update && apt upgrade`.
- **Installa** i pacchetti essenziali elencati in `ESSENTIAL_PACKAGES` (strumenti come build-essential, curl, git, ufw, htop, net-tools, ecc.).
- **Crea** il nuovo utente `NEW_USER`, gli assegna gli stessi gruppi (aggiungendo `sudo`), imposta la password e aggiunge l’alias `updg` nel file `.bash_aliases`.
- **Crea un file di swap** eseguendo lo script `make_swap.sh`: `/swapfile` grande quanto la RAM (anche col fallback `dd`), registrato in `/etc/fstab`. Se `/swapfile` è già attivo non fa nulla; se `fallocate`/`dd`, `mkswap` o `swapon` falliscono esce con errore, senza dichiarare lo swap pronto né scrivere in `fstab`.
- **Aggiorna** il file `setup_info` con `NEXT_STAGE=2`.
- **Riavvia** il sistema.

---

### Stage 2 – Rimozione vecchio utente, SSH, UFW e installazione Docker

- **Rimuove** completamente l’utente originale `OLD_USER` (utente di default di molte VPS, es. `debian`).
- **Modifica la porta SSH** nel file `/etc/ssh/sshd_config` impostandola a `NEW_SSH_PORT`. Disabilita anche il login di root via SSH.
- **Riavvia** il servizio `sshd`. Se `ssh.socket` è attivo (Ubuntu 22.10+: con l'attivazione via socket `sshd` ignora `Port` di `sshd_config`) lo disattiva e abilita `ssh`. Poi **verifica** con `ss` che `sshd` ascolti davvero sulla nuova porta: se no si ferma con un errore (`NEXT_STAGE` resta 2) *prima* di abilitare UFW e riavviare, perché UFW chiude la 22 e il server resterebbe senza nessun accesso SSH. Risolto il problema basta rilanciare `setup.sh`.
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
- **Riavvia** il sistema. Prima del riavvio il log indica dove creare il `.env` dello stage 3: `/etc/server_setup/<cartella del repo>/services/.env` (da `example.env`, con `sudo`: la cartella è solo di root).

---

### Stage 3 – Servizi Docker (NPM, CrowdSec, Portainer, ecc.)

- **Ferma e disabilita** Apache (se installato) per liberare le porte 80/443.
- **Apre le porte firewall** necessarie: 80, 443, 1195 (VPN personale). Portainer non ha una porta propria: si raggiunge da `portainer.<dominio>` tramite NPM. L'admin di NPM (81) e Open WebUI (3000) sono pubblicate **solo su localhost**: da fuori Open WebUI si raggiunge da `webui.<dominio>` (con TLS e controllo CrowdSec), l'admin di NPM con un tunnel SSH (`ssh -L 8081:127.0.0.1:81 -p <porta> <utente>@<server>`, poi `http://127.0.0.1:8081`).
- **Copia** la cartella `services` nella home del nuovo utente (se esiste già la riusa: modifica lì il `.env`) e la intesta al nuovo utente; il `.env`, con le credenziali, è `0600`.
- **Si posiziona** nella directory `services` e:
    - Verifica che `.env` esista (altrimenti si ferma: copia `example.env` in `.env` e rilancia). Il file non viene "sourced": è la sintassi di Compose, non quella della shell.
    - Verifica che nel `.env` non sia rimasto nessun valore di `example.env`: segnaposto `change_me_*`, `SERVER_DOMAIN=example.com`, email `@example.com` (Let's Encrypt le rifiuta). Se ce ne sono si ferma **prima di avviare qualsiasi cosa** e stampa i *nomi* delle variabili (mai i valori): senza questo controllo Portainer nascerebbe con una password nota, e dà accesso al socket di Docker, cioè root sull'host.
    - Genera una password casuale per il database di NPM e la inserisce nel file `.env` al posto del segnaposto `NPM_DB_PASSWORD=change_me_npm_db_password` (o `npm_db_password`, anche tra virgolette o con spazi finali); la riga deve essere *solo* il segnaposto: una password scelta a mano, anche se inizia allo stesso modo (`npm_db_password_prod`), non viene toccata.
- **Crea la rete docker `proxynet`** se non esiste (nel compose è `external`).
- **Avvia** tutti i container con `docker compose up -d`. Se fallisce lo stage si ferma, senza avanzare.
- **Attende i container di configurazione** `npm-init` e, se il profilo `portainer` è attivo, `portainer-init` (`docker wait`, massimo 20 minuti ciascuno) e ne controlla l'esito: se uno esce con errore (certificato Let's Encrypt non ottenuto, login fallito, admin Portainer non creato) lo stage si ferma senza avanzare. Rilanciando `setup.sh`, `docker compose up -d` riavvia gli init già usciti. Niente più attesa a tempo: CrowdSec ha un controllo di prontezza suo.
- **Se il profilo `server` è attivo** (CrowdSec tra i servizi di Compose; altrimenti salta tutto questo):
    - Attende che CrowdSec sia davvero pronto: `cscli lapi status`, fino a 24 tentativi (`cscli version` risponde subito, prima che la LAPI sia su).
    - Genera la chiave API del bouncer con `cscli bouncers add npm-bouncer` (se il bouncer esiste già da un tentativo precedente lo ricrea) e la scrive in `.env` (`CROWDSEC_BOUNCER_API_KEY`).
    - Ricrea il container `cs-bouncer` per applicare la nuova chiave e verifica che risponda `200` al ForwardAuth.
    - Solo a questo punto imposta `CROWDSEC_FORWARD_AUTH_URL` in `.env` e ricrea `npm-init`, che attiva il controllo su tutti i proxy host. Fino ad allora i proxy host sono raggiungibili senza controllo, ma non c'è nessuna finestra in cui rispondano 403/500: vedi [CrowdSec e NPM](#crowdsec-e-npm). Se `npm-init` fallisce (ad esempio nginx rifiuta il blocco), l'attivazione viene annullata: l'URL torna vuota in `.env` e `npm-init` viene rilanciato per togliere il blocco da NPM.
    - Se uno di questi passaggi fallisce lo stage si ferma con un errore **senza avanzare** (`NEXT_STAGE` resta 3): risolto il problema basta rilanciare `setup.sh`.
- **Aggiorna** il file `setup_info` con `NEXT_STAGE=4`.
- **Riavvia** il sistema.

---

### Stage 4 – Completamento

- La fase successiva (NEXT_STAGE diverso da 1,2,3) stampa semplicemente “Setup is finished. System ready!” e termina, perché tutto è stato configurato.

### Altre funzioni di supporto

- `log()`: scrive messaggi con timestamp su file `/var/log/setup.log` e su console.
- `update_info_file()`: riscrive il file `setup_info` con i parametri attuali e il prossimo stage (in modo atomico; se non riesce lo stage si ferma).

### Riepilogo dei risultati finali

Una volta completato lo script, il server avrà:

- Un nuovo utente con permessi sudo e gruppi ereditati dall’utente originale.
- Accesso SSH su una porta personalizzata (e root disabilitato).
- Firewall UFW attivo con sole porte necessarie aperte (SSH, 80, 443, 1195).
- Swap configurato (grande quanto la RAM).
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
- **Blocco**: se `CROWDSEC_FORWARD_AUTH_URL` è valorizzata in `.env`, `npm-init` scrive in `/data/nginx/custom/server_proxy.conf` (volume `npm_data`, montato in lettura/scrittura in `npm-init`) un blocco con un `auth_request` verso `cs-bouncer`. NPM include quel file in **ogni** proxy host, anche quelli creati dalla UI e non presenti nel descriptor: gli IP con una decisione di ban ricevono 403. Il blocco è delimitato da marcatori e il resto del file non viene toccato; se la variabile è vuota il blocco viene rimosso. Le richieste `/.well-known/acme-challenge/` sono **sempre ammesse**: sono la validazione HTTP-01 di Let's Encrypt, e con il bouncer giù o la chiave non valida il rinnovo dei certificati fallirebbe in silenzio.

Il blocco è *fail-closed*: con una chiave bouncer non valida, o con `cs-bouncer` fermo o assente, i proxy host rispondono 403/500. Per questo `CROWDSEC_FORWARD_AUTH_URL` in `example.env` è **vuota**: la imposta `setup.sh` (stage 3) dopo aver generato la chiave e verificato che il bouncer risponda, e solo se il profilo `server` è attivo. Se la imposti a mano, il profilo `server` deve essere attivo; se lo togli da `COMPOSE_PROFILES` svuota anche la variabile. In locale (`.env.local`) non è definita e non cambia nulla.

Su un server già installato prima di questa modifica, dopo aver aggiornato il repo:

```bash
cd services
docker compose up -d                  # ricrea npm e open-webui con le porte 81 e 3000 solo su localhost, e npm-init con il nuovo volume
docker compose up -d npm-init         # riallinea gli host e scrive il blocco globale (se la variabile è già in .env)
```

Se nginx rifiuta il blocco (tipico: un host creato dalla UI ha ancora il vecchio snippet per-host, e `location = /crowdsec-auth` risulterebbe due volte), `npm-init` esce con errore **dopo aver ripristinato** `server_proxy.conf` com'era e aver risalvato l'host perché NPM lo riattivi: il file rifiutato non resta sul volume (altrimenti ogni salvataggio successivo, anche dalla UI, darebbe errore). Per risolvere togli l'`advanced_config` con il vecchio snippet da quell'host e rilancia `docker compose up -d npm-init`. Se un file rifiutato è già rimasto sul volume (versioni precedenti), svuota `CROWDSEC_FORWARD_AUTH_URL` e rilancia `npm-init` per rimuovere il blocco.

`npm-init` prima allinea gli host del descriptor (l'`advanced_config` del vecchio snippet per-host sparisce) e solo dopo scrive il blocco globale, poi fa ricaricare nginx. Se `CROWDSEC_FORWARD_AUTH_URL` non è ancora in `.env`, aggiungi `CROWDSEC_FORWARD_AUTH_URL=http://cs-bouncer:8080/api/v1/forwardAuth` solo dopo aver verificato che il bouncer risponda: `docker exec npm curl -s -o /dev/null -w '%{http_code}' http://cs-bouncer:8080/api/v1/forwardAuth` deve stampare `200` (403 = chiave non valida).

## Test

I test sono in `tests/` e non toccano il sistema: `setup.sh` gira in una sandbox con i percorsi di sistema riscritti e `sudo`, `apt`, `ufw`, `systemctl`, `docker`, `reboot`... sostituiti da shim che registrano le chiamate; `npm-init` gira contro un NPM finto (`tests/mock_npm.py`); la parte ACME usa un nginx vero in Docker.

```bash
tests/run.sh                     # tutti
tests/run.sh t_stage3 t_swap     # solo alcuni
SS_ROOT=/percorso/di/un/albero tests/run.sh   # prova un altro albero (es. un vecchio commit estratto con git archive)
```

Servono `bash`, `jq`, `curl`, `python3`; `t_nginx_acme` usa Docker e salta se manca l'immagine `nginx:1.27-alpine`. Non sostituiscono la prova sullo stack vero (vedi la skill `verify`): lo stage 3 e `sshd` reali non si possono eseguire in sandbox.

## Crowdsec utils

```bash
docker exec crowdsec cscli alerts list      # IP bannati
docker exec crowdsec cscli decisions list   # decisioni attive
docker exec crowdsec cscli metrics          # statistiche
```

# Endpoints

