#!/bin/bash
# Stage 3 di setup.sh (stack docker, bouncer CrowdSec): #1 segnaposto, #3 container init,
# #4 rollback, #6 password DB, #14 log in italiano. docker è finto (tests/shims/docker).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

HOME_ENV=""
new_stage3() {   # prepara sandbox + albero di stage + setup_info (stage 3) + .env "good"
    unset FAKE_SERVICES FAKE_UP_RC FAKE_LAPI_READY_AFTER FAKE_FWD_CODE FAKE_RECREATE_RC FAKE_NETWORK_RC
    new_sandbox
    install_stage_tree
    write_info 3
    make_env "${1:-good}"
    HOME_ENV="$SB/home/testuser/services/.env"
}
SERVER_PROFILE="npm npm-db npm-init portainer portainer-init vpn-personal crowdsec cs-bouncer"
NO_SERVER_PROFILE="npm npm-db npm-init portainer portainer-init"
set_env_line() { sed -i "s|^$1=.*|$1=$2|" "$SB/etc/server_setup/server-setup/services/.env"; }

# ------------------------------------------------------------------------------
echo "# controllo: stack con profilo server, tutto bene"
new_stage3
run_stage
assert_eq "stage 3 termina con successo" "0" "$RC"
assert_eq "NEXT_STAGE passa a 4" "4" "$(next_stage)"
assert_match "la chiave del bouncer finisce nel .env" '^FAKEBOUNCERKEY' "$(env_value CROWDSEC_BOUNCER_API_KEY "$HOME_ENV")"
assert_eq "CROWDSEC_FORWARD_AUTH_URL impostata a bouncer verificato" "http://cs-bouncer:8080/api/v1/forwardAuth" "$(env_value CROWDSEC_FORWARD_AUTH_URL "$HOME_ENV")"
assert_eq ".env del nuovo utente è 0600" "600" "$(stat -c %a "$HOME_ENV")"
assert_match "la password del DB di NPM è stata generata" '^[A-Za-z0-9]{12}$' "$(env_value NPM_DB_PASSWORD "$HOME_ENV")"
assert_called "il bouncer viene ricreato" '^RECREATE cs-bouncer'
assert_called "npm-init viene ricreato con l'URL" '^RECREATE npm-init env: CROWDSEC_FORWARD_AUTH_URL=http'

# ------------------------------------------------------------------------------
echo "# #1: .env con i valori di esempio non modificati"
new_stage3 example
export FAKE_SERVICES="$SERVER_PROFILE"
run_stage
assert_eq "#1 lo stage si ferma con errore" "1" "$RC"
assert_not_called "#1 nessun servizio viene avviato con le credenziali di esempio" '^docker compose up'
assert_eq "#1 NEXT_STAGE resta 3" "3" "$(next_stage)"
log_tail=$(tail -5 "$SB/var/log/setup.log")
assert_match "#1 l'errore elenca le variabili da cambiare" 'PORTAINER_ADMIN_PASSWORD' "$log_tail"
assert_match "#1 elenca anche il dominio" 'SERVER_DOMAIN' "$log_tail"
assert_no_match "#1 il log non stampa i valori di esempio" 'change_me_portainer' "$log_tail"

new_stage3
set_env_line SERVER_DOMAIN example.com
run_stage
assert_eq "#1 SERVER_DOMAIN=example.com (Let's Encrypt fallirebbe) blocca lo stage" "1" "$RC"
assert_not_called "#1 con il dominio di esempio non parte nulla" '^docker compose up'

new_stage3
set_env_line NPM_ADMIN_EMAIL admin@example.com
run_stage
assert_eq "#1 email @example.com (rifiutata da Let's Encrypt) blocca lo stage" "1" "$RC"

new_stage3
set_env_line PORTAINER_ADMIN_PASSWORD change_me_portainer_password
run_stage
assert_eq "#1 una sola password rimasta di esempio blocca lo stage" "1" "$RC"
assert_not_called "#1 e non parte nulla" '^docker compose up'

# ------------------------------------------------------------------------------
echo "# #6: sostituzione del segnaposto NPM_DB_PASSWORD"
db_case() {   # descrizione riga-.env atteso(regex)
    new_stage3
    set_env_line NPM_DB_PASSWORD "$2"
    run_stage
    assert_match "$1" "$3" "$(env_value NPM_DB_PASSWORD "$HOME_ENV")"
}
db_case "segnaposto di example.env sostituito" 'change_me_npm_db_password' '^[A-Za-z0-9]{12}$'
db_case "segnaposto nudo (npm_db_password) sostituito" 'npm_db_password' '^[A-Za-z0-9]{12}$'
db_case "#6 segnaposto tra virgolette sostituito" '"change_me_npm_db_password"' '^[A-Za-z0-9]{12}$'
db_case "#6 segnaposto con spazi finali sostituito" 'change_me_npm_db_password  ' '^[A-Za-z0-9]{12}$'
db_case "#6 password scelta a mano che inizia come il segnaposto resta intatta" 'npm_db_password_prod' '^npm_db_password_prod$'
db_case "#6 idem con altro suffisso" 'npm_db_password2' '^npm_db_password2$'
db_case "password scelta a mano resta intatta" 'Gh7kLm2pQx' '^Gh7kLm2pQx$'

# ------------------------------------------------------------------------------
echo "# #3: esito dei container init"
new_stage3
export FAKE_SERVICES="$NO_SERVER_PROFILE"
echo 1 > "$SB/state/wait_npm-init"
run_stage
assert_eq "#3 senza profilo server, npm-init fallito ferma lo stage" "1" "$RC"
assert_eq "#3 NEXT_STAGE resta 3" "3" "$(next_stage)"
assert_not_called "#3 nessun reboot" '^reboot'

new_stage3
export FAKE_SERVICES="$NO_SERVER_PROFILE"
echo 1 > "$SB/state/wait_portainer-init"
run_stage
assert_eq "#3 portainer-init fallito ferma lo stage" "1" "$RC"
assert_eq "#3 NEXT_STAGE resta 3" "3" "$(next_stage)"

new_stage3
export FAKE_SERVICES="$NO_SERVER_PROFILE"
run_stage
assert_eq "#3 init riusciti: lo stage termina" "0" "$RC"
assert_eq "#3 NEXT_STAGE passa a 4" "4" "$(next_stage)"
assert_called "#3 attende npm-init" '^docker wait npm-init'
assert_called "#3 attende portainer-init (profilo attivo)" '^docker wait portainer-init'
assert_not_called "#3 niente attesa cieca di 200 secondi" '^sleep 20$'

new_stage3
export FAKE_SERVICES="npm npm-db npm-init"
run_stage
assert_not_called "#3 senza profilo portainer non attende portainer-init" '^docker wait portainer-init'
assert_eq "#3 e lo stage termina comunque" "0" "$RC"

new_stage3
export FAKE_SERVICES="$SERVER_PROFILE"
run_stage
w=$(first_line_of '^docker wait npm-init'); l=$(first_line_of 'cscli lapi status')
if [[ -n "$w" && -n "$l" && $w -lt $l ]]; then ok "#3 npm-init finisce prima di toccare CrowdSec (niente ricreazione a metà richiesta LE)"; else ko "#3 npm-init finisce prima di toccare CrowdSec" "prima attesa npm-init: ${w:-mai}, lapi status: ${l:-mai}"; fi

# ------------------------------------------------------------------------------
echo "# #4: npm-init fallisce dopo l'attivazione di CrowdSec"
new_stage3
export FAKE_SERVICES="$SERVER_PROFILE"
printf '0\n1\n0\n' > "$SB/state/wait_npm-init"    # 1ª esecuzione ok, 2ª (con URL) fallisce, 3ª (rollback) ok
run_stage
assert_eq "#4 lo stage si ferma con errore" "1" "$RC"
assert_eq "#4 NEXT_STAGE resta 3" "3" "$(next_stage)"
assert_eq "#4 l'URL del forward-auth non resta nel .env" "" "$(env_value CROWDSEC_FORWARD_AUTH_URL "$HOME_ENV")"
last_npm_init=$(grep '^RECREATE npm-init' "$SB/calls.log" | tail -1)
assert_match "#4 npm-init viene rilanciato senza URL per togliere il blocco" 'env: CROWDSEC_FORWARD_AUTH_URL= \|' "$last_npm_init"

# ------------------------------------------------------------------------------
echo "# controlli sul comportamento già corretto"
new_stage3
export FAKE_SERVICES="$SERVER_PROFILE" FAKE_FWD_CODE=403
run_stage
assert_eq "bouncer che risponde 403: lo stage si ferma" "1" "$RC"
assert_eq "e l'URL non viene mai impostato" "" "$(env_value CROWDSEC_FORWARD_AUTH_URL "$HOME_ENV")"
assert_not_called "e npm-init non viene ricreato" '^RECREATE npm-init'

new_stage3
export FAKE_SERVICES="$SERVER_PROFILE" FAKE_LAPI_READY_AFTER=999
run_stage
assert_eq "CrowdSec mai pronto: lo stage si ferma" "1" "$RC"
assert_eq "NEXT_STAGE resta 3" "3" "$(next_stage)"

new_stage3
export FAKE_UP_RC=1
run_stage
assert_eq "compose up fallito: lo stage si ferma" "1" "$RC"
assert_eq "NEXT_STAGE resta 3" "3" "$(next_stage)"

new_stage3
rm "$SB/etc/server_setup/server-setup/services/.env"
run_stage
assert_eq ".env mancante: lo stage si ferma" "1" "$RC"
assert_not_called "e non avvia nulla" '^docker compose up'

new_stage3
export FAKE_SERVICES="$NO_SERVER_PROFILE"
run_stage
assert_not_called "senza profilo server nessuna chiamata a cscli" 'cscli'

# ------------------------------------------------------------------------------
echo "# #1: find_env_placeholders, casi limite"
# shellcheck source=/dev/null
source <(sed -n '/^find_env_placeholders()/,/^}/p' "$SS_ROOT/setup.sh")
cat > "$SB/edge.env" <<'EOS'
# SERVER_DOMAIN=example.com   (commento: ignorato)
A_PLACEHOLDER=change_me_something
B_DOMAIN=example.com
C_QUOTED="example.com"
D_MAIL=admin@example.com
E_URL=https://www.example.com/x
F_REAL=mydomain.org
G_LOOKALIKE=myexample.com
H_LOOKALIKE=example.company
I_REAL_MAIL=me@my-example.com.au.org
J_EMPTY=
EOS
assert_eq "segnala segnaposto, example.com, email e URL di example.com; ignora domini veri, commenti e nomi simili" \
    "A_PLACEHOLDER B_DOMAIN C_QUOTED D_MAIL E_URL" "$(find_env_placeholders "$SB/edge.env" | paste -sd' ' -)"

# ------------------------------------------------------------------------------
echo "# #14: i messaggi di log sono in italiano"
english='(^|[^A-Za-z])(Waiting|Generating|Recreating|Enabling|ERROR|failed|Failed|did not|cannot|Fix the problem|not found|not active|not ready|skipping|Check)([^A-Za-z]|$)'
# shellcheck disable=SC2016  # i pattern sed/grep contengono $ letterali
mapfile -t new_logs < <(
    { sed -n '/^setup_crowdsec_bouncer()/,/^}/p;/^enable_crowdsec_forward_auth()/,/^}/p' "$SS_ROOT/setup.sh"
      sed -n '/^elif \[\[ "\$NEXT_STAGE" == "3" \]\]/,/^else$/p' "$SS_ROOT/setup.sh"; } |
    grep -o 'log "[^"]*"')
assert_true "estratti i messaggi di log della sezione CrowdSec/stage 3" test "${#new_logs[@]}" -gt 10
bad=()
for m in "${new_logs[@]}"; do [[ "$m" =~ $english ]] && bad+=("$m"); done
if [[ ${#bad[@]} -eq 0 ]]; then ok "#14 nessun messaggio in inglese nella sezione CrowdSec e nello stage 3"; else ko "#14 messaggi ancora in inglese: ${#bad[@]}" "${bad[@]:0:6}"; fi

finish
