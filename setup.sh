#!/bin/bash

LOG_FILE_PATH="/var/log/setup.log"
log ()
{
    log_str="$(date '+%d/%m/%Y %H:%M:%S') $1"
    echo "$log_str" >> "$LOG_FILE_PATH"
    echo -e "\n[### LOG ###] $log_str"
}


# Check if script hsa been executed as root
if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root" 
    exit 1
fi

SETUP_DATA_FOLDER="/etc/server_setup"
INFO_FILE_PATH="$SETUP_DATA_FOLDER/setup_info"
ESSENTIAL_PACKAGES="build-essential htop curl git-all apt-show-versions libapt-pkg-perl libauthen-pam-perl libio-pty-perl ufw lshw net-tools rsync cron"
# Endpoint ForwardAuth di cs-bouncer, raggiungibile dalla rete docker proxynet
CROWDSEC_FORWARD_AUTH_URL="http://cs-bouncer:8080/api/v1/forwardAuth"

update_info_file()
{
    if [[ $# -ne 8 ]] ; then
        log "Invalid update_info_file parameters count"
        return 1
    fi

    # Il file viene letto con "source" da root a ogni stage e contiene la password
    # in chiaro: i valori sono quotati con %q (niente espansioni né comandi eseguiti)
    # e il file è leggibile solo dal proprietario (mktemp crea il file con modo 0600).
    # Il nuovo contenuto va prima in un file temporaneo nella stessa cartella e sostituisce
    # il vecchio con un solo "mv" a scrittura completata: se la macchina si ferma o la
    # scrittura fallisce a metà, il file di stato precedente resta intatto (cancellarlo
    # prima lascerebbe il provisioning senza stato: "Not existing info file").
    local tmp
    tmp=$(mktemp "$INFO_FILE_PATH.XXXXXX") || { log "Cannot create a temporary file next to $INFO_FILE_PATH"; return 1; }
    if ! {
        printf 'OLD_USER=%q\n' "$1" &&
        printf 'NEW_USER=%q\n' "$2" &&
        printf 'NEW_USER_PASSW=%q\n' "$3" &&
        printf 'NEW_SSH_PORT=%q\n' "$4" &&
        printf 'NEW_USER_GROUPS=%q\n' "$5" &&
        printf 'SETUP_DATA_FOLDER=%q\n' "$6" &&
        printf 'SCRIPT_DIR_NAME=%q\n' "$7" &&
        printf 'NEXT_STAGE=%q\n' "$8"
    } > "$tmp" || ! mv -f "$tmp" "$INFO_FILE_PATH"; then
        rm -f "$tmp"
        log "Cannot update $INFO_FILE_PATH (the previous content is unchanged)"
        return 1
    fi
}

# Ritorna 0 appena qualcosa ascolta (TCP) sulla porta $1, riprovando per qualche secondo.
wait_for_listening_port()
{
    local port="$1" i
    for i in $(seq 1 10); do
        [[ -n "$(ss -ltnH "sport = :$port" 2> /dev/null)" ]] && return 0
        sleep 1
    done
    return 1
}

# Imposta KEY=valore in un file env di compose: sostituisce la riga se c'è, altrimenti
# la aggiunge. Il file viene riscritto sul posto (proprietario e permessi restano).
set_env_var()
{
    local file="$1" key="$2" value="$3" tmp
    tmp=$(mktemp) || return 1
    KEY="$key" VAL="$value" awk 'BEGIN { FS = "="; k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
        $1 == k { print k "=" v; found = 1; next }
        { print }
        END { if (!found) print k "=" v }' "$file" > "$tmp" && cat "$tmp" > "$file"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# Attesa massima della fine di un container one-shot (npm-init può dover ottenere un
# certificato Let's Encrypt): oltre, lo stage si ferma invece di restare appeso.
INIT_WAIT_TIMEOUT_S=1200

# Attende la fine del container one-shot $1 (npm-init, portainer-init). Ritorna 0 solo se è
# terminato con codice 0: un init fallito lascia NPM senza host o Portainer senza admin
# (e Portainer si blocca da solo dopo 5 minuti), quindi lo stage non deve andare avanti.
wait_init_container()
{
    local name="$1" rc
    log "Attendo la fine di $name..."
    if ! rc=$(timeout "$INIT_WAIT_TIMEOUT_S" docker wait "$name"); then
        rc="nessuna risposta entro ${INIT_WAIT_TIMEOUT_S}s"
    fi
    if [[ "$rc" != "0" ]]; then
        log "ERRORE: $name non è andato a buon fine (esito: $rc). Controlla 'docker logs $name'."
        return 1
    fi
    log "$name completato"
}

# Stampa (una per riga) le variabili del file env $1 rimaste a un valore di example.env:
# i segnaposto "change_me_*", il dominio example.com e le email @example.com (Let's Encrypt
# rifiuta i contatti di example.com). Se partisse lo stack così, Portainer e gli altri
# servizi nascerebbero con credenziali note e pubbliche. Stampa solo i nomi, mai i valori.
find_env_placeholders()
{
    grep -E "^[A-Za-z_][A-Za-z0-9_]*=(.*change_me_|[\"']?(.*[@.])?example\.com([^A-Za-z0-9-]|\$))" "$1" | cut -d= -f1
}

# Genera la chiave del bouncer CrowdSec, la scrive nel .env ($1) e verifica che
# cs-bouncer la accetti. Ritorna 1 al primo problema: lo stage non deve andare avanti
# con proxy host che rispondono 403/500 (l'auth_request verso il bouncer è fail-closed).
setup_crowdsec_bouncer()
{
    local env_file="$1" crowdsec_ready=0 bouncer_key code i

    # "cscli version" risponde appena il container è su senza contattare la LAPI:
    # "lapi status" invece riesce solo quando CrowdSec è davvero pronto.
    log "Attendo che CrowdSec sia pronto..."
    for i in $(seq 1 24); do
        if docker exec crowdsec cscli lapi status > /dev/null 2>&1; then
            crowdsec_ready=1
            break
        fi
        log "CrowdSec non è ancora pronto, riprovo tra 5s... ($i/24)"
        sleep 5
    done
    if [[ $crowdsec_ready -eq 0 ]]; then
        log "ERRORE: CrowdSec non è diventato pronto in tempo. Controlla 'docker logs crowdsec'."
        return 1
    fi

    log "Genero la chiave API del bouncer CrowdSec..."
    # A uno stage rilanciato il bouncer esiste già ("add" fallirebbe): lo si ricrea.
    docker exec crowdsec cscli bouncers delete npm-bouncer > /dev/null 2>&1 || true
    bouncer_key=$(docker exec crowdsec cscli bouncers add npm-bouncer -o raw 2>/dev/null)
    if [[ -z "$bouncer_key" ]]; then
        log "ERRORE: impossibile generare la chiave del bouncer. Controlla 'docker logs crowdsec'."
        return 1
    fi
    log "Chiave del bouncer generata"
    set_env_var "$env_file" CROWDSEC_BOUNCER_API_KEY "$bouncer_key" || { log "ERRORE: impossibile scrivere la chiave in $env_file"; return 1; }

    log "Ricreo cs-bouncer con la nuova chiave API..."
    # "docker compose restart" non rilegge .env: il container terrebbe la vecchia chiave.
    docker compose up -d --no-deps --force-recreate cs-bouncer || { log "ERRORE: impossibile ricreare cs-bouncer"; return 1; }

    # Prova che la chiave funziona: il forwardAuth risponde 200 per un IP non bannato
    # (403 con una chiave non valida, nessuna risposta se il bouncer è giù).
    code=000
    for i in $(seq 1 12); do
        code=$(docker exec npm curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 127.0.0.1' \
            "$CROWDSEC_FORWARD_AUTH_URL" 2>/dev/null)
        [[ "$code" == "200" ]] && break
        sleep 5
    done
    if [[ "$code" != "200" ]]; then
        log "ERRORE: cs-bouncer risponde HTTP $code invece di 200. Controlla 'docker logs cs-bouncer' e 'docker exec crowdsec cscli bouncers list'."
        return 1
    fi
    log "Bouncer CrowdSec pronto. Verifica con: docker exec crowdsec cscli bouncers list"
}

# Attiva l'auth_request CrowdSec sui proxy host: scrive CROWDSEC_FORWARD_AUTH_URL nel .env ($1)
# e rilancia npm-init, che scrive il blocco nginx globale. Da chiamare solo a bouncer verificato
# (setup_crowdsec_bouncer): l'auth_request è fail-closed, con un bouncer che non risponde
# i proxy host danno 403/500. Per questo l'URL non è già in example.env.
# Se npm-init non riesce, l'attivazione viene annullata (disable_crowdsec_forward_auth): un
# URL lasciato nel .env o un blocco rifiutato da nginx farebbero fallire ogni salvataggio
# successivo dei proxy host, anche dalla UI di NPM.
enable_crowdsec_forward_auth()
{
    local env_file="$1"

    log "Attivo il controllo CrowdSec (forward-auth) sui proxy host di NPM..."
    set_env_var "$env_file" CROWDSEC_FORWARD_AUTH_URL "$CROWDSEC_FORWARD_AUTH_URL" || { log "ERRORE: impossibile scrivere CROWDSEC_FORWARD_AUTH_URL in $env_file"; return 1; }
    # npm-init è one-shot e "restart" non rilegge .env: lo si ricrea, così riparte con l'URL.
    if ! { docker compose up -d --no-deps --force-recreate npm-init && wait_init_container npm-init; }; then
        log "ERRORE: npm-init non ha attivato il controllo CrowdSec: lo disattivo"
        disable_crowdsec_forward_auth "$env_file"
        return 1
    fi
    log "Controllo CrowdSec attivo"
}

# Annulla enable_crowdsec_forward_auth: svuota l'URL nel .env ($1) e rilancia npm-init, che
# toglie il blocco CrowdSec da NPM. Best effort: lo stage è già in errore.
disable_crowdsec_forward_auth()
{
    local env_file="$1"

    set_env_var "$env_file" CROWDSEC_FORWARD_AUTH_URL "" || log "ATTENZIONE: impossibile svuotare CROWDSEC_FORWARD_AUTH_URL in $env_file: fallo a mano"
    if docker compose up -d --no-deps --force-recreate npm-init && wait_init_container npm-init; then
        log "Controllo CrowdSec disattivato (URL vuota nel .env, blocco tolto da NPM)"
    else
        log "ATTENZIONE: npm-init non è riuscito a togliere il blocco CrowdSec da NPM: controlla 'docker logs npm-init'"
    fi
}

if [[ ! -d "$SETUP_DATA_FOLDER" ]]; then

    # Check if correct number of arguments provided
    if [[ $# -ne 3 ]]; then
        echo "Error: 3 parameters required!"
        echo "Usage: $0 <new_user> <new_password> <ssh_port>"
        exit 1
    fi

    OLD_USER="${SUDO_USER:-${USER}}"
    NEW_USER="$1"
    NEW_USER_PASSW="$2"
    NEW_SSH_PORT="$3"

    PRIMARY_GROUP=$(id -gn "$OLD_USER")
    # Gruppi dell'utente originale (non del gruppo omonimo: "id" vuole un utente) tranne il primario,
    # confrontato per nome intero: un gruppo "dev-ops" non va mutilato se il primario è "dev".
    NEW_USER_GROUPS=$(id -Gn "$OLD_USER" | tr ' ' '\n' | grep -vxF "$PRIMARY_GROUP" | paste -sd, -)

    SCRIPT_DIR_PATH=$(dirname "$(readlink -f "$0")")
    SCRIPT_DIR_NAME=$(basename "$SCRIPT_DIR_PATH")

    # Asking for user confirmation
    echo "Running setup script as $OLD_USER"
    echo \
    "Setting up system with following configuration:
        Old user: $OLD_USER
        New user: $NEW_USER
        Password: $NEW_USER_PASSW
        Groups: $NEW_USER_GROUPS
        SSH port: $NEW_SSH_PORT
        SCRIPT_DIR_PATH: $SCRIPT_DIR_PATH
        SCRIPT_DIR_NAME: $SCRIPT_DIR_NAME
        SETUP_DATA_FOLDER: $SETUP_DATA_FOLDER"
    
    read -r -p "Continue? (y/N): " confirm && [[ $confirm == [y] ]] || exit 1

    # Making installation folder
    # Solo root: la copia del repo contiene anche services/.env con le credenziali, e resta
    # qui fino allo stage 4 (il modo 0700 vale già dalla creazione, prima di copiare).
    mkdir -m 700 "$SETUP_DATA_FOLDER" || exit 1
    cd "$SETUP_DATA_FOLDER" || exit 1
    cp -r "$SCRIPT_DIR_PATH" .
    chmod +x "./$SCRIPT_DIR_NAME/setup.sh"
    ln -s "$SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME/setup.sh" "/usr/local/bin/setup.sh"
    chmod +x "/usr/local/bin/setup.sh"

    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "1" || exit 1

    log "Rebooting system. SSH as '$OLD_USER' and launch setup.sh script"
    sudo reboot
    exit 0
fi


if [[ ! -f "$INFO_FILE_PATH" ]]; then
    log "Not existing info file: $INFO_FILE_PATH"
    exit 1
fi

# shellcheck source=/dev/null
source "$INFO_FILE_PATH"
cd "$SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME" || exit 1
log "Setup info file found. Next stage:$NEXT_STAGE"
log "Current user $USER"
sleep 2

# -------------------------------
# ----------  Stage 1  ----------
if [[ "$NEXT_STAGE" == "1" ]]; then

    # Update and upgrade
    log "Updating packages"
    sudo apt update && sudo apt upgrade -y


    # Installing essential packages
    log "Installign packages"
    sudo apt install -y --install-recommends $ESSENTIAL_PACKAGES


    # Add NEW_USER user
    log "Adding $NEW_USER user"
    sudo useradd -m -G "$NEW_USER_GROUPS" -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_USER_PASSW" | sudo chpasswd
    echo "alias updg='sudo apt update && sudo apt upgrade'" >> /home/"$NEW_USER"/.bash_aliases
    sudo usermod -aG sudo $NEW_USER


    # Install swap file
    log "Making swap memory"
    bash "$SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME/make_swap.sh"


    # Updating INFO_FILE_PATH
    log "Updating info file path"
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "2" || exit 1

    log "Rebooting system. SSH as '$NEW_USER' and launch setup.sh script"
    sudo reboot


elif [[ "$NEXT_STAGE" == "2" ]]; then

    log "Inside stage 2"

    # Delete 'debian' user
    log "Removing $OLD_USER user"
    sudo deluser --remove-home "$OLD_USER"


    # Change ssh port to NEW_SSH_PORT
    log "Changing SSH port"
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bkp
    sudo sed -i "s/^#\?Port [0-9]*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    # Deny ssh connections from root user
    if grep -q "^#\?PermitRootLogin" /etc/ssh/sshd_config; then
        sudo sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
    fi
    # Con l'attivazione via socket (ssh.socket, Ubuntu 22.10+) sshd ignora "Port" di
    # sshd_config e ascolta dove dice il socket: lo si disattiva e si abilita il servizio.
    if systemctl is-active --quiet ssh.socket; then
        log "ssh.socket è attivo: lo disattivo, così sshd usa la porta di sshd_config"
        sudo systemctl disable --now ssh.socket
        sudo systemctl enable ssh
    fi
    sudo systemctl restart sshd
    # Prima di chiudere la porta vecchia con UFW si controlla che sshd ascolti davvero su
    # quella nuova (sshd_config.d o socket possono averla ignorata): se no il reboot
    # lascerebbe il server senza nessun accesso SSH.
    if ! wait_for_listening_port "$NEW_SSH_PORT"; then
        log "ERRORE: sshd non ascolta sulla porta $NEW_SSH_PORT. Non abilito UFW né riavvio, per non restare senza accesso: controlla /etc/ssh/sshd_config, /etc/ssh/sshd_config.d/ e 'systemctl status ssh', poi rilancia setup.sh (lo stage 2 si può ripetere)"
        exit 1
    fi


    # Setup UFW
    log "Setting up UFW"
    sudo sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow "$NEW_SSH_PORT"
    # "systemctl enable" da solo non basta: /etc/ufw/ufw.conf parte con ENABLED=no e
    # ufw-init non applica nessuna regola finché "ufw enable" non lo mette a yes.
    # La porta SSH è già aperta sopra: la sessione in corso non cade.
    sudo ufw --force enable
    sudo systemctl enable ufw


    # Installing Docker
    log "Installing Docker"
    LINUX_DISTRO="$(hostnamectl | grep "Operating System" | cut -d':' -f2 | xargs | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
    # Rimuove i pacchetti in conflitto, ma solo quelli installati: la lista deve essere
    # un argomento per pacchetto (e non vuota), altrimenti apt fallisce; -y per non bloccare lo stage.
    mapfile -t old_docker_pkgs < <(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc 2> /dev/null | awk '$2 == "install" {print $1}')
    if [[ ${#old_docker_pkgs[@]} -gt 0 ]]; then
        log "Removing conflicting packages: ${old_docker_pkgs[*]}"
        sudo apt remove -y "${old_docker_pkgs[@]}"
    fi
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/$LINUX_DISTRO/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$LINUX_DISTRO
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $NEW_USER


    # Updating INFO_FILE_PATH
    log "Updating info file path"
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "3" || exit 1

    log "Riavvio. Collegati come '$NEW_USER', crea $SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME/services/.env partendo da example.env (con sudo: la cartella è accessibile solo a root), modificalo e rilancia setup.sh"
    sudo reboot


elif [[ "$NEXT_STAGE" == "3" ]] ; then
    
    log "Inside stage 3"

    sudo systemctl stop apache2
    sudo systemctl disable apache2

    # Setup docker services
    # NPM admin (81) e Open WebUI (3000) sono pubblicate solo su localhost: niente regole.
    sudo ufw allow "80"
    sudo ufw allow "443"
    sudo ufw allow "1195" # Personal VPN
    SERVICES_D="/home/$NEW_USER/services"
    # Lo stage si può rilanciare dopo un errore: senza questo controllo "cp -r"
    # annida la cartella (services/services) invece di riusare quella esistente.
    if [[ -d "$SERVICES_D" ]]; then
        log "$SERVICES_D già presente, la riuso (modifica lì il file .env, non l'originale)"
    else
        cp -r services "/home/$NEW_USER"
    fi
    cd "$SERVICES_D" || exit 1
    # Il .env è il file di Compose (non sintassi shell): non va "sourced" da root, basta che esista.
    if [[ ! -f .env ]]; then
        log "ERRORE: $SERVICES_D/.env non trovato. Copia example.env in .env (in $SERVICES_D, oppure in $SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME/services prima del primo avvio di questo stage), modificalo e rilancia setup.sh"
        exit 1
    fi
    # Lo stage gira da root: la copia va intestata al nuovo utente (deve poter modificare
    # .env e i file di configurazione) e il .env, con le credenziali, solo a lui.
    chown -R "$NEW_USER:" "$SERVICES_D" || { log "ERRORE: impossibile cambiare il proprietario di $SERVICES_D"; exit 1; }
    chmod 600 .env
    npm_db_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    # Sostituisce il segnaposto sia nella forma di example.env (change_me_npm_db_password)
    # sia in quella nuda (npm_db_password), anche tra virgolette e con spazi finali; la riga deve
    # essere solo il segnaposto: una password scelta a mano che inizia allo stesso modo
    # (es. npm_db_password_prod) resta intatta.
    sed -i "s/^NPM_DB_PASSWORD=[\"']\{0,1\}\(change_me_\)\{0,1\}npm_db_password[\"']\{0,1\}[[:space:]]*$/NPM_DB_PASSWORD=$npm_db_password/" .env

    # Prima di avviare qualunque cosa: nessun valore di example.env deve essere rimasto.
    placeholders=$(find_env_placeholders .env | paste -sd' ' -)
    if [[ -n "$placeholders" ]]; then
        log "ERRORE: in $SERVICES_D/.env ci sono ancora i valori di esempio di example.env: $placeholders. Impostali (dominio, email, password e token veri: i servizi nascerebbero con credenziali note) e rilancia setup.sh"
        exit 1
    fi

    log "Attivo i servizi.."
    # proxynet è "external" nel compose: se non esiste "up" non avvia nulla.
    if ! docker network inspect proxynet > /dev/null 2>&1; then
        log "Creo la rete docker proxynet"
        docker network create proxynet || { log "ERRORE: impossibile creare la rete docker proxynet"; exit 1; }
    fi
    if ! docker compose up -d; then
        log "ERRORE: docker compose up non è riuscito. Correggi il problema e rilancia setup.sh (lo stage 3 si può ripetere)"
        exit 1
    fi

    # I container one-shot configurano NPM (certificato, proxy host) e Portainer (admin): si
    # attende la loro fine, invece di dormire a tempo, e si controlla l'esito. Un init fallito
    # ferma lo stage (rilanciandolo "docker compose up -d" riavvia gli init già usciti).
    mapfile -t active_services < <(docker compose config --services)
    for init_service in npm-init portainer-init; do
        printf '%s\n' "${active_services[@]}" | grep -qx "$init_service" || continue
        if ! wait_init_container "$init_service"; then
            log "Correggi il problema e rilancia setup.sh (lo stage 3 si può ripetere)"
            exit 1
        fi
    done

    # Generate CrowdSec bouncer API key and inject into .env (solo se il profilo "server" è attivo)
    if docker compose config --services | grep -qx crowdsec; then
        if ! { setup_crowdsec_bouncer "$SERVICES_D/.env" && enable_crowdsec_forward_auth "$SERVICES_D/.env"; }; then
            log "Configurazione CrowdSec non riuscita. Correggi il problema e rilancia setup.sh (lo stage 3 si può ripetere)"
            exit 1
        fi
    else
        log "Servizio CrowdSec non attivo (profilo 'server' assente): salto la generazione della chiave del bouncer"
    fi


    # Updating INFO_FILE_PATH
    log "Updating info file path"
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "4" || exit 1

    log "Rebooting system. SSH as '$NEW_USER' and launch setup.sh script"
    sudo reboot


else
    log "Setup is finished. System ready!"

    rm -fr "/usr/local/bin/setup.sh" $SETUP_DATA_FOLDER
fi