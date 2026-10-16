#!/bin/bash
# services/npm-init/setup.sh contro un NPM finto (tests/mock_npm.py): #2 certificati falliti,
# #4 rollback del blocco CrowdSec, #9 campi del descriptor inviati a NPM.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

new_sandbox
DATA="$SB/npm-data"
CONF="$DATA/nginx/custom/server_proxy.conf"
MOCK_PID=""
stop_mock() { [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2> /dev/null; MOCK_PID=""; }
on_exit stop_mock

# fresh_mock: nuovo NPM finto con stato pulito; i flag si creano con "flag nome"
fresh_mock() {
    stop_mock
    rm -rf "$SB/mock" "$DATA"; mkdir -p "$SB/mock" "$DATA"
    python3 "$TESTS_DIR/mock_npm.py" "$SB/mock" "$CONF" &
    MOCK_PID=$!
    for _ in $(seq 1 50); do [[ -s "$SB/mock/port" ]] && break; sleep 0.1; done
    PORT=$(< "$SB/mock/port")
}
flag() { : > "$SB/mock/$1"; }

# run_init: esegue lo script vero. Variabili opzionali: PROVIDER, DESC, FWD_URL
run_init() {
    RC=0
    OUT=$(NPM_ADMIN_EMAIL=admin@mydomain.org NPM_ADMIN_PASSWORD='pw"x\y' SERVER_DOMAIN=mydomain.org \
          NPM_API_URL="http://127.0.0.1:$PORT/api" DESCRIPTOR_FILE="${DESC:-$SS_ROOT/services/npm-init/descriptor.json}" \
          NPM_CERT_PROVIDER="${PROVIDER:-letsencrypt}" NPM_DATA_DIR="$DATA" CROWDSEC_FORWARD_AUTH_URL="${FWD_URL:-}" \
          bash "$SS_ROOT/services/npm-init/setup.sh" 2>&1) || RC=$?
}
reqs() { jq -c "$1" -s "$SB/mock/requests.log" 2> /dev/null; }       # reqs 'filtro jq su array di richieste'
count_reqs() { reqs "[.[] | select($1)] | length"; }

HOSTS_POST='.method=="POST" and .path=="/api/nginx/proxy-hosts"'
CERTS_POST='.method=="POST" and .path=="/api/nginx/certificates"'

# ------------------------------------------------------------------------------
echo "# controllo: Let's Encrypt riesce"
fresh_mock; unset DESC PROVIDER FWD_URL
run_init
assert_eq "npm-init termina con successo" "0" "$RC"
assert_eq "crea i 2 proxy host del descriptor" "2" "$(count_reqs "$HOSTS_POST")"
assert_eq "gli host usano il certificato appena creato" "[1,1]" "$(reqs "[.[] | select($HOSTS_POST) | .body.certificate_id]")"
assert_false "senza URL CrowdSec non scrive nessun blocco globale" test -e "$CONF"

# ------------------------------------------------------------------------------
echo "# #2: richiesta del certificato fallita"
fresh_mock; flag le_fail
run_init
assert_eq "#2 Let's Encrypt fallito: npm-init esce con errore" "1" "$RC"
assert_eq "#2 nessun proxy host creato con certificate_id=0 (andrebbero in chiaro)" "0" "$(count_reqs "$HOSTS_POST")"

fresh_mock; flag upload_fail; PROVIDER=local
run_init
assert_eq "#2 certificato locale: upload fallito, npm-init esce con errore" "1" "$RC"
assert_eq "#2 nessun proxy host creato" "0" "$(count_reqs "$HOSTS_POST")"

fresh_mock; PROVIDER=local
run_init
assert_eq "controllo: certificato locale riuscito" "0" "$RC"
assert_eq "controllo: host creati" "2" "$(count_reqs "$HOSTS_POST")"
unset PROVIDER

# ------------------------------------------------------------------------------
echo "# #9: campi del descriptor inviati a NPM"
fresh_mock
run_init
assert_eq "#9 trust_forwarded_proto=true del descriptor arriva a NPM (entrambi gli host)" "[true,true]" \
    "$(reqs "[.[] | select($HOSTS_POST) | .body.trust_forwarded_proto]")"

# descriptor senza il campo: resta false
jq 'del(.proxyHosts[].trust_forwarded_proto)' "$SS_ROOT/services/npm-init/descriptor.json" > "$SB/desc_no_tfp.json"
fresh_mock; DESC="$SB/desc_no_tfp.json" run_init
assert_eq "#9 senza il campo nel descriptor NPM riceve false" "[false,false]" \
    "$(reqs "[.[] | select($HOSTS_POST) | .body.trust_forwarded_proto]")"

# letsencrypt.agree: NPM accetta i termini da solo, quindi il consenso va letto dal descriptor
jq '.localCertificate.letsencrypt.agree = false' "$SS_ROOT/services/npm-init/descriptor.json" > "$SB/desc_noagree.json"
fresh_mock; DESC="$SB/desc_noagree.json" run_init
assert_eq "#9 letsencrypt.agree=false: npm-init esce con errore" "1" "$RC"
assert_eq "#9 e non chiede nessun certificato a Let's Encrypt" "0" "$(count_reqs "$CERTS_POST")"
assert_match "#9 l'errore parla dei termini di servizio" 'agree|termini' "$OUT"
fresh_mock
run_init
assert_eq "#9 con agree=true il certificato viene chiesto" "1" "$(count_reqs "$CERTS_POST")"

# ------------------------------------------------------------------------------
FWD='http://cs-bouncer:8080/api/v1/forwardAuth'
echo "# controllo: blocco CrowdSec globale scritto e accettato"
fresh_mock
FWD_URL=$FWD run_init
assert_eq "npm-init termina con successo" "0" "$RC"
assert_match "il blocco è in server_proxy.conf" 'auth_request /crowdsec-auth;' "$(cat "$CONF" 2> /dev/null)"

echo "# #4: nginx rifiuta il blocco CrowdSec globale"
fresh_mock; flag reject_global
mkdir -p "$(dirname "$CONF")"; printf 'client_max_body_size 50m;\n' > "$CONF"
FWD_URL=$FWD run_init
assert_eq "#4 npm-init esce con errore" "1" "$RC"
assert_eq "#4 il file torna com'era (il contenuto messo a mano resta, il blocco rifiutato sparisce)" \
    'client_max_body_size 50m;' "$(cat "$CONF" 2> /dev/null)"
assert_eq "#4 NPM non resta con l'host con nginx_online=false" "true" \
    "$(curl -s "http://127.0.0.1:$PORT/api/nginx/proxy-hosts/1" | jq -r '.meta.nginx_online')"

fresh_mock; flag reject_global
FWD_URL=$FWD run_init
assert_eq "#4 senza file preesistente: esce con errore" "1" "$RC"
assert_false "#4 e il file con il blocco rifiutato non resta sul volume" test -e "$CONF"
assert_eq "#4 l'host viene riportato online" "true" \
    "$(curl -s "http://127.0.0.1:$PORT/api/nginx/proxy-hosts/1" | jq -r '.meta.nginx_online')"

finish
