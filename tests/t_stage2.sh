#!/bin/bash
# Stage 2 di setup.sh: cambio porta SSH + UFW (#7) e messaggio finale (#13).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup_stage2() {
    new_sandbox
    install_stage_tree
    write_info 2
    printf 'Operating System: Debian GNU/Linux 12 (bookworm)\n' > "$SB/state/hostnamectl.out"
    cat > "$SB/behave/hostnamectl" <<'EOS'
cat "$SB/state/hostnamectl.out"
EOS
    cat > "$SB/behave/curl" <<'EOS'
touch "$SB/etc/apt/keyrings/docker.asc"
EOS
}
# listening: 1 = sshd ascolta sulla nuova porta subito, 0 = mai,
#            socket = ascolta solo dopo che ssh.socket è stato disattivato (Ubuntu 24.04)
set_ssh_behaviour() {
    case "$1" in
        1)
            cat > "$SB/behave/systemctl" <<'EOS'
case "$1" in is-active) exit 3 ;; esac
EOS
            cat > "$SB/behave/ss" <<'EOS'
echo "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*"
EOS
            ;;
        0)
            cat > "$SB/behave/systemctl" <<'EOS'
case "$1" in is-active) exit 3 ;; esac
EOS
            ;;
        socket)
            cat > "$SB/behave/systemctl" <<'EOS'
case "$*" in
    "is-active --quiet ssh.socket"|"is-active ssh.socket") [[ -f "$SB/state/socket_off" ]] && exit 3; exit 0 ;;
    "disable --now ssh.socket"|"stop ssh.socket") touch "$SB/state/socket_off"; exit 0 ;;
    is-active*) exit 3 ;;
esac
EOS
            cat > "$SB/behave/ss" <<'EOS'
[[ -f "$SB/state/socket_off" ]] && echo "LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*"
EOS
            ;;
    esac
}

echo "# sshd ascolta sulla nuova porta (caso normale)"
setup_stage2; set_ssh_behaviour 1
run_stage
assert_eq "stage 2 termina con successo" "0" "$RC"
assert_match "sshd_config ha la nuova porta" '^Port 2222$' "$(grep '^Port' "$SB/etc/ssh/sshd_config")"
assert_called "UFW viene abilitato" '^ufw --force enable'

assert_eq "NEXT_STAGE passa a 3" "3" "$(next_stage)"
assert_called "chiede il reboot" '^reboot'

# #13: il messaggio dice dove mettere il .env che lo stage 3 leggerà davvero
reboot_msg=$(tail -1 "$SB/var/log/setup.log")   # l'ultimo messaggio dello stage è quello prima del reboot
assert_match "#13 il messaggio finale indica la cartella services letta dallo stage 3" "$SB/etc/server_setup/server-setup/services" "$reboot_msg"

echo "# sshd NON ascolta sulla nuova porta (#7)"
setup_stage2; set_ssh_behaviour 0
run_stage
assert_eq "#7 lo stage si ferma con errore" "1" "$RC"
assert_not_called "#7 UFW non viene abilitato (si chiuderebbe la porta 22 lasciando fuori ogni accesso)" '^ufw --force enable'

assert_not_called "#7 nessun reboot" '^reboot'

assert_eq "#7 NEXT_STAGE resta 2" "2" "$(next_stage)"
assert_match "#7 l'errore dice quale porta non risponde" '2222' "$(tail -3 "$SB/var/log/setup.log")"

echo "# ssh.socket attivo (Ubuntu 24.04: la porta di sshd_config è ignorata) (#7)"
setup_stage2; set_ssh_behaviour socket
run_stage
assert_eq "#7 con ssh.socket lo stage riesce" "0" "$RC"
assert_called "#7 ssh.socket viene disattivato così sshd usa sshd_config" '^systemctl disable --now ssh.socket'

assert_called "#7 poi UFW viene abilitato" '^ufw --force enable'

assert_eq "#7 NEXT_STAGE passa a 3" "3" "$(next_stage)"
sock_line=$(first_line_of '^systemctl disable --now ssh.socket'); ufw_line=$(first_line_of '^ufw --force enable')
if [[ -n "$sock_line" && -n "$ufw_line" && $sock_line -lt $ufw_line ]]; then ok "#7 ssh.socket viene sistemato prima di abilitare UFW"; else ko "#7 ssh.socket viene sistemato prima di abilitare UFW" "socket: ${sock_line:-mai} ufw: ${ufw_line:-mai}"; fi

finish
