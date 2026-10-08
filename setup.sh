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

update_info_file()
{
    if [[ $# -ne 8 ]] ; then
        log "Invalid update_info_file parameters count"
        return
    fi

    rm -f "$INFO_FILE_PATH"
    touch "$INFO_FILE_PATH"
    echo "OLD_USER=$1" >> "$INFO_FILE_PATH"
    echo "NEW_USER=$2" >> "$INFO_FILE_PATH"
    echo "NEW_USER_PASSW=$3" >> "$INFO_FILE_PATH"
    echo "NEW_SSH_PORT=$4" >> "$INFO_FILE_PATH"
    echo "NEW_USER_GROUPS=$5" >> "$INFO_FILE_PATH"
    echo "SETUP_DATA_FOLDER=$6" >> "$INFO_FILE_PATH"
    echo "SCRIPT_DIR_NAME=$7" >> "$INFO_FILE_PATH"
    echo "NEXT_STAGE=$8" >> "$INFO_FILE_PATH"
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
    cd "$SETUP_DATA_FOLDER"
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

source "$INFO_FILE_PATH"
cd "$SETUP_DATA_FOLDER/$SCRIPT_DIR_NAME"
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
    sudo systemctl enable ufw
    sudo systemctl reload ufw


    # Installing Docker
    log "Installing Docker"
    LINUX_DISTRO="$(hostnamectl | grep "Operating System" | cut -d':' -f2 | xargs | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
    sudo apt remove "$(dpkg --get-selections docker.io docker-compose docker-doc podman-docker containerd runc | cut -f1)" && sudo apt update
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
    sudo ufw allow "80"
    sudo ufw allow "443"
    sudo ufw allow "81"
    sudo ufw allow "9443" # Portainer
    sudo ufw allow "1195" # Personal VPN
    sudo ufw allow "3000" # Open WebUI
    cp -r services "/home/$NEW_USER"
    SERVICES_D="/home/$NEW_USER/services"
    cd "$SERVICES_D"
    source "./.env"
    npm_db_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    sed -i "s/npm_db_password/$npm_db_password/g" .env

    log "Activating services.."
    docker compose up -d
    
    # Sleeping for 200 seconds
    SLEEP_AMOUNT_S=200
    SLEEP_INTERVAL_S=20
    for (( i=0; i<=$SLEEP_AMOUNT_S; i+=$SLEEP_INTERVAL_S )); do
        echo "Elapsed time: $i seconds"
        if [ $i -lt $SLEEP_AMOUNT_S ]; then
            sleep $SLEEP_INTERVAL_S
        fi
    done

    # Generate CrowdSec bouncer API key and inject into .env
    log "Waiting for CrowdSec to be ready..."
    crowdsec_ready=0
    for i in $(seq 1 24); do
        if docker exec crowdsec cscli version > /dev/null 2>&1; then
            crowdsec_ready=1
            break
        fi
        log "CrowdSec not ready yet, retrying in 5s... ($i/24)"
        sleep 5
    done

    if [[ $crowdsec_ready -eq 0 ]]; then
        log "ERROR: CrowdSec did not become ready in time. Bouncer key NOT generated."
        log "Run manually: docker exec crowdsec cscli bouncers add npm-bouncer"
        log "Then update CROWDSEC_BOUNCER_API_KEY in $SERVICES_D/.env and restart cs-bouncer"
    else
        log "Generating CrowdSec bouncer API key..."
        crowdsec_bouncer_key=$(docker exec crowdsec cscli bouncers add npm-bouncer -o raw 2>/dev/null)

        if [[ -z "$crowdsec_bouncer_key" ]]; then
            log "ERROR: Failed to generate bouncer key. Check 'docker logs crowdsec'."
        else
            log "Bouncer key generated successfully"
            # Write key into .env (replace placeholder if present, otherwise append)
            if grep -q "^CROWDSEC_BOUNCER_API_KEY=" "$SERVICES_D/.env"; then
                sed -i "s|^CROWDSEC_BOUNCER_API_KEY=.*|CROWDSEC_BOUNCER_API_KEY=$crowdsec_bouncer_key|" "$SERVICES_D/.env"
            else
                echo "CROWDSEC_BOUNCER_API_KEY=$crowdsec_bouncer_key" >> "$SERVICES_D/.env"
            fi
            log "Restarting cs-bouncer with the new API key..."
            docker compose restart cs-bouncer
            log "CrowdSec setup complete. Verify with: docker exec crowdsec cscli bouncers list"
        fi
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