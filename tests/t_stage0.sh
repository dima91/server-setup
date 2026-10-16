#!/bin/bash
# Stage 0 di setup.sh (prima esecuzione, copia in /etc/server_setup): #5 permessi, #8 gruppi,
# #13 messaggio d'uso. setup.sh gira in sandbox con gli shim di tests/shims.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

run_stage0() {   # argomenti di setup.sh
    run_in_sandbox -i $'y\n' "$SB/src/server-setup/setup.sh" "$@"
}
# shellcheck source=/dev/null
groups_of_new_user() { ( source "$SB/etc/server_setup/setup_info" && printf '%s' "$NEW_USER_GROUPS" ); }

echo "# stage 0: esecuzione normale"
new_sandbox
printf 'SERVER_DOMAIN=example.com\nNPM_ADMIN_PASSWORD=segreto\n' > "$SB/src/server-setup/services/.env"
chmod 664 "$SB/src/server-setup/services/.env"
run_stage0 newuser 'pw' 2222
assert_eq "stage 0 termina con successo" "0" "$RC"
assert_eq "NEXT_STAGE è 1" "1" "$(next_stage)"
assert_called "chiede il reboot" '^reboot'


# #5: la copia del repo in /etc/server_setup contiene services/.env (con le credenziali):
# finché lo stage 4 non la cancella non deve essere leggibile da altri utenti.
assert_eq "#5 /etc/server_setup accessibile solo al proprietario" "700" "$(stat -c %a "$SB/etc/server_setup")"
assert_eq "setup_info è 0600" "600" "$(stat -c %a "$SB/etc/server_setup/setup_info")"
copied_env="$SB/etc/server_setup/server-setup/services/.env"
assert_true "services/.env è stato copiato" test -f "$copied_env"
if [[ "$(stat -c %a "$SB/etc/server_setup")" == "700" ]] || [[ "$(stat -c %a "$copied_env")" == "600" ]]; then
    ok "#5 il .env copiato non è leggibile da altri"
else
    ko "#5 il .env copiato non è leggibile da altri" "cartella $(stat -c %a "$SB/etc/server_setup"), file $(stat -c %a "$copied_env")"
fi

echo "# stage 0: gruppi dell'utente originale (#8)"
new_sandbox
cat > "$SB/behave/id" <<'EOS'
# utente "admin" con gruppo primario "users" (nome diverso dall'utente)
case "$*" in
    "-gn admin") echo users; exit 0 ;;
    "-Gn admin") echo "users adm sudo-x"; exit 0 ;;
    "-Gn users") echo "id: 'users': no such user" >&2; exit 1 ;;
esac
EOS
run_stage0 newuser 'pw' 2222
assert_eq "#8 gruppo primario con nome diverso dall'utente: eredita gli altri gruppi" "adm,sudo-x" "$(groups_of_new_user)"

new_sandbox
export SUDO_USER_FOR_TEST=dev
cat > "$SB/behave/id" <<'EOS'
# utente "dev" con gruppo primario "dev" e un gruppo "dev-ops" che inizia con lo stesso nome
case "$*" in
    "-gn dev") echo dev; exit 0 ;;
    "-Gn dev") echo "dev dev-ops adm"; exit 0 ;;
esac
EOS
run_stage0 newuser 'pw' 2222
unset SUDO_USER_FOR_TEST
assert_eq "#8 un gruppo il cui nome inizia come il primario (dev-ops) non viene mutilato" "dev-ops,adm" "$(groups_of_new_user)"

echo "# stage 0: numero di parametri (#13)"
new_sandbox
run_stage0 solo_uno
assert_eq "senza i 3 parametri esce con 1" "1" "$RC"
assert_match "#13 il messaggio d'uso dice 3 parametri" 'Error: 3 parameters required' "$OUT"
assert_no_match "#13 il messaggio d'uso non parla più di 10 parametri" '10 parameters' "$OUT"
assert_false "nessuna cartella creata" test -d "$SB/etc/server_setup"

finish
