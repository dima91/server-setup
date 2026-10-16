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
        return
    fi

    # Il file viene letto con "source" da root a ogni stage e contiene la password
    # in chiaro: i valori sono quotati con %q (niente espansioni né comandi eseguiti)
    # e il file è leggibile solo dal proprietario.
    rm -f "$INFO_FILE_PATH"
    (
        umask 077
        {
            printf 'OLD_USER=%q\n' "$1"
            printf 'NEW_USER=%q\n' "$2"
            printf 'NEW_USER_PASSW=%q\n' "$3"
            printf 'NEW_SSH_PORT=%q\n' "$4"
            printf 'NEW_USER_GROUPS=%q\n' "$5"
            printf 'SETUP_DATA_FOLDER=%q\n' "$6"
            printf 'SCRIPT_DIR_NAME=%q\n' "$7"
            printf 'NEXT_STAGE=%q\n' "$8"
        } > "$INFO_FILE_PATH"
    )
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

# Genera la chiave del bouncer CrowdSec, la scrive nel .env ($1) e verifica che
# cs-bouncer la accetti. Ritorna 1 al primo problema: lo stage non deve andare avanti
# con proxy host che rispondono 403/500 (l'auth_request verso il bouncer è fail-closed).
setup_crowdsec_bouncer()
{
    local env_file="$1" crowdsec_ready=0 bouncer_key code i

    # "cscli version" risponde appena il container è su senza contattare la LAPI:
    # "lapi status" invece riesce solo quando CrowdSec è davvero pronto.
    log "Waiting for CrowdSec to be ready..."
    for i in $(seq 1 24); do
        if docker exec crowdsec cscli lapi status > /dev/null 2>&1; then
            crowdsec_ready=1
            break
        fi
        log "CrowdSec not ready yet, retrying in 5s... ($i/24)"
        sleep 5
    done
    if [[ $crowdsec_ready -eq 0 ]]; then
        log "ERROR: CrowdSec did not become ready in time. Check 'docker logs crowdsec'."
        return 1
    fi

    log "Generating CrowdSec bouncer API key..."
    # A uno stage rilanciato il bouncer esiste già ("add" fallirebbe): lo si ricrea.
    docker exec crowdsec cscli bouncers delete npm-bouncer > /dev/null 2>&1 || true
    bouncer_key=$(docker exec crowdsec cscli bouncers add npm-bouncer -o raw 2>/dev/null)
    if [[ -z "$bouncer_key" ]]; then
        log "ERROR: Failed to generate bouncer key. Check 'docker logs crowdsec'."
        return 1
    fi
    log "Bouncer key generated successfully"
    set_env_var "$env_file" CROWDSEC_BOUNCER_API_KEY "$bouncer_key" || { log "ERROR: cannot write the key into $env_file"; return 1; }

    log "Recreating cs-bouncer with the new API key..."
    # "docker compose restart" non rilegge .env: il container terrebbe la vecchia chiave.
    docker compose up -d --no-deps --force-recreate cs-bouncer || { log "ERROR: cannot recreate cs-bouncer"; return 1; }

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
        log "ERROR: cs-bouncer answers HTTP $code instead of 200. Check 'docker logs cs-bouncer' and 'docker exec crowdsec cscli bouncers list'."
        return 1
    fi
    log "CrowdSec setup complete. Verify with: docker exec crowdsec cscli bouncers list"
}

# Attiva l'auth_request CrowdSec sui proxy host: scrive CROWDSEC_FORWARD_AUTH_URL nel .env ($1)
# e rilancia npm-init, che scrive il blocco nginx globale. Da chiamare solo a bouncer verificato
# (setup_crowdsec_bouncer): l'auth_request è fail-closed, con un bouncer che non risponde
# i proxy host danno 403/500. Per questo l'URL non è già in example.env.
enable_crowdsec_forward_auth()
{
    local env_file="$1" npm_init_exit

    log "Enabling CrowdSec forward-auth on the NPM proxy hosts..."
    set_env_var "$env_file" CROWDSEC_FORWARD_AUTH_URL "$CROWDSEC_FORWARD_AUTH_URL" || { log "ERROR: cannot write CROWDSEC_FORWARD_AUTH_URL into $env_file"; return 1; }
    # npm-init è one-shot e "restart" non rilegge .env: lo si ricrea, così riparte con l'URL.
    docker compose up -d --no-deps --force-recreate npm-init || { log "ERROR: cannot recreate npm-init"; return 1; }
    npm_init_exit=$(docker wait npm-init)
    if [[ "$npm_init_exit" != "0" ]]; then
        log "ERROR: npm-init failed (exit $npm_init_exit). Check 'docker logs npm-init'."
        return 1
    fi
    log "CrowdSec forward-auth enabled"
}

if [[ ! -d "$SETUP_DATA_FOLDER" ]]; then

    # Check if correct number of arguments provided
    if [[ $# -ne 3 ]]; then
        echo "Error: 10 parameters required!"
        echo "Usage: $0 <new_user> <new_password> <ssh_port>"
        exit 1
    fi

    OLD_USER="${SUDO_USER:-${USER}}"
    NEW_USER="$1"
    NEW_USER_PASSW="$2"
    NEW_SSH_PORT="$3"

    PRIMARY_GROUP=$(id -gn "$OLD_USER")
    NEW_USER_GROUPS=$(id -Gn "$PRIMARY_GROUP" | sed "s/\b$PRIMARY_GROUP\b//g" | sed 's/  */ /g' | tr ' ' ',' | sed 's/^,//;s/,$//')

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
    mkdir $SETUP_DATA_FOLDER
    cd "$SETUP_DATA_FOLDER" || exit 1
    cp -r "$SCRIPT_DIR_PATH" .
    chmod +x "./$SCRIPT_DIR_NAME/setup.sh"
    ln -s "$SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME/setup.sh" "/usr/local/bin/setup.sh"
    chmod +x "/usr/local/bin/setup.sh"

    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "1"

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
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "2"

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
    sudo systemctl restart sshd


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
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "3"

    log "Rebooting system. SSH as '$NEW_USER', edit docker-compose and .env in $SETUP_DATA_FOLDER and launch setup.sh script"
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
        log "ERROR: $SERVICES_D/.env not found. Copy example.env to .env, edit it and launch setup.sh again"
        exit 1
    fi
    # Lo stage gira da root: la copia va intestata al nuovo utente (deve poter modificare
    # .env e i file di configurazione) e il .env, con le credenziali, solo a lui.
    chown -R "$NEW_USER:" "$SERVICES_D" || { log "ERROR: cannot change owner of $SERVICES_D"; exit 1; }
    chmod 600 .env
    npm_db_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    # Sostituisce il segnaposto sia nella forma di example.env (change_me_npm_db_password)
    # sia in quella nuda (npm_db_password); una password già scelta a mano resta intatta.
    sed -i "s/^NPM_DB_PASSWORD=\(change_me_\)\{0,1\}npm_db_password/NPM_DB_PASSWORD=$npm_db_password/" .env

    log "Activating services.."
    # proxynet è "external" nel compose: se non esiste "up" non avvia nulla.
    if ! docker network inspect proxynet > /dev/null 2>&1; then
        log "Creating docker network proxynet"
        docker network create proxynet || { log "ERROR: cannot create docker network proxynet"; exit 1; }
    fi
    if ! docker compose up -d; then
        log "ERROR: docker compose up failed. Fix the problem and launch setup.sh again (stage 3 can be repeated)"
        exit 1
    fi

    # Sleeping for 200 seconds
    SLEEP_AMOUNT_S=200
    SLEEP_INTERVAL_S=20
    for (( i=0; i<=$SLEEP_AMOUNT_S; i+=$SLEEP_INTERVAL_S )); do
        echo "Elapsed time: $i seconds"
        if [ $i -lt $SLEEP_AMOUNT_S ]; then
            sleep $SLEEP_INTERVAL_S
        fi
    done

    # Generate CrowdSec bouncer API key and inject into .env (solo se il profilo "server" è attivo)
    if docker compose config --services | grep -qx crowdsec; then
        if ! { setup_crowdsec_bouncer "$SERVICES_D/.env" && enable_crowdsec_forward_auth "$SERVICES_D/.env"; }; then
            log "CrowdSec setup failed. Fix the problem and launch setup.sh again (stage 3 can be repeated)"
            exit 1
        fi
    else
        log "CrowdSec service not active (no 'server' profile): skipping bouncer key generation"
    fi


    # Updating INFO_FILE_PATH
    log "Updating info file path"
    update_info_file "$OLD_USER" "$NEW_USER" "$NEW_USER_PASSW" "$NEW_SSH_PORT" "$NEW_USER_GROUPS" "$SETUP_DATA_FOLDER" "$SCRIPT_DIR_NAME" "4"

    log "Rebooting system. SSH as '$NEW_USER' and launch setup.sh script"
    sudo reboot


else
    log "Setup is finished. System ready!"

    rm -fr "/usr/local/bin/setup.sh" $SETUP_DATA_FOLDER
fi