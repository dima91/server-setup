#!/bin/bash
# =============================================================================
# setup.sh - NPM auto-config via API (certificati + proxy hosts + locations)
# Richiede: bash, curl, jq
# =============================================================================
#set -euo pipefail

# --- Configurazione da variabili d'ambiente ---
NPM_API_URL="${NPM_API_URL:-http://npm:81/api}"
NPM_EMAIL="${NPM_ADMIN_EMAIL:-}"
NPM_PASSWORD="${NPM_ADMIN_PASSWORD:-}"
DESCRIPTOR="${DESCRIPTOR_FILE:-/services/npm-init/descriptor.json}"
SERVER_DOMAIN="${SERVER_DOMAIN:-localhost}"
# URL ForwardAuth del bouncer CrowdSec (vuota = nessuna protezione, es. in locale)
CROWDSEC_FORWARD_AUTH_URL="${CROWDSEC_FORWARD_AUTH_URL:-}"

log() { echo "[npm-setup] $(date '+%H:%M:%S') $*" >&2; }

TOKEN=""
CERTIFICATE_ID=0

# -----------------------------------------------------------------------------
wait_for_npm() {
    log "Attendo NPM API: $NPM_API_URL ..."
    local max=60 count=0
    while (( count < max )); do
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' "$NPM_API_URL/" 2>/dev/null || echo "000")
        [[ "$code" == "200" ]] && { log "NPM API pronta!"; return 0; }
        (( ++count ))
        sleep 3
        echo "Retrying.."
    done
    log "ERRORE: NPM non raggiungibile dopo ${max} tentativi"
    return 1
}

# -----------------------------------------------------------------------------
authenticate() {
    log "Autenticazione NPM ..."
    local resp
    # Il corpo è costruito con jq: virgolette e backslash nella password vanno escapati.
    resp=$(jq -n --arg identity "$NPM_EMAIL" --arg secret "$NPM_PASSWORD" '{identity:$identity, secret:$secret}' | \
        curl -s -X POST "$NPM_API_URL/tokens" \
            -H "Content-Type: application/json" \
            -d @-)
    TOKEN=$(echo "$resp" | jq -r '.token // empty')
    [[ -z "$TOKEN" ]] && { log "ERRORE auth: $resp"; return 1; }
    log "Autenticazione OK."
}

# -----------------------------------------------------------------------------
# Risolve ${SERVER_DOMAIN} in una stringa JSON di domini via jq
# -----------------------------------------------------------------------------
resolve_domains() {
    local json_array="$1"   # JSON array di domini
    echo "$json_array" | jq -c '[.[] | sub("\\$\\{SERVER_DOMAIN\\}"; $SD)]' --arg SD "$SERVER_DOMAIN"
}

# =============================================================================
# SEZIONE CERTIFICATI
# =============================================================================

# -----------------------------------------------------------------------------
# create_certificate
#   - serverCertificate presente → carica certificato custom
#   - altrimenti → genera un certificato locale o Let's Encrypt in base al provider
# -----------------------------------------------------------------------------
create_certificate() {
    if jq -e '.serverCertificate' "$DESCRIPTOR" &>/dev/null; then
        create_custom_certificate
        return
    fi

    local provider
    provider=$(jq -r '.localCertificate.provider // "letsencrypt"' "$DESCRIPTOR")
    # NPM_CERT_PROVIDER (env) ha priorità sul valore nel descriptor, per poter
    # usare lo stesso descriptor.json sia in locale (self-signed) che su server (LE).
    provider="${NPM_CERT_PROVIDER:-$provider}"
    if [[ "$provider" == "local" ]]; then
        create_local_certificate
    else
        create_letsencrypt_certificate
    fi
}

create_letsencrypt_certificate() {
    jq -e '.localCertificate' "$DESCRIPTOR" &>/dev/null || { log "localCertificate assente, skip."; return 0; }

    local enabled name domains le_dns
    enabled=$(jq -r '.localCertificate.enabled // false' "$DESCRIPTOR")
    [[ "$enabled" != "true" ]] && { log "localCertificate disabilitato, skip."; return 0; }
    name=$(jq -r '.localCertificate.name // "letsencrypt-cert"' "$DESCRIPTOR")
    domains=$(jq -c '.localCertificate.domains' "$DESCRIPTOR")
    domains=$(resolve_domains "$domains")
    le_dns=$(jq -r '.localCertificate.letsencrypt.dns_challenge // false' "$DESCRIPTOR")

    # Già esistente? Per i cert Let's Encrypt NPM ignora il nome richiesto e imposta
    # nice_name = elenco dei domini: oltre al nome si cerca quindi un cert LE con
    # esattamente gli stessi domini, altrimenti ogni rilancio ne chiederebbe uno nuovo
    # (rate limit di Let's Encrypt, cert orfani).
    local existing_id
    existing_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$NPM_API_URL/nginx/certificates" | \
        jq -r --arg name "$name" --argjson domains "$domains" \
            '.[] | select(.nice_name == $name or (.provider == "letsencrypt" and ((.domain_names | sort) == ($domains | sort)))) | .id' | head -1) || true
    [[ -n "$existing_id" ]] && { log "Cert LE '$name' già presente (ID: $existing_id)."; CERTIFICATE_ID="$existing_id"; return 0; }

    # NPM accetta da solo i termini di servizio di Let's Encrypt quando richiede un certificato
    # (certbot --agree-tos): il consenso del descriptor è l'unico modo di non darlo implicitamente.
    local agree
    agree=$(jq -r 'if .localCertificate.letsencrypt.agree == null then true else .localCertificate.letsencrypt.agree end' "$DESCRIPTOR")
    if [[ "$agree" != "true" ]]; then
        log "ERRORE: localCertificate.letsencrypt.agree non è true nel descriptor: NPM accetta i termini di servizio di Let's Encrypt in automatico, quindi senza il tuo consenso esplicito non richiedo il certificato."
        return 1
    fi

    log "Richiesta LE '$name' per: $(echo "$domains" | jq -r 'join(", ")' ) ..."

    local resp
    resp=$(jq -n --arg name "$name" --argjson domains "$domains" \
            --argjson dns_challenge "$le_dns" \
            '{nice_name:$name, domain_names:$domains, provider:"letsencrypt", meta:{dns_challenge:$dns_challenge}}' | \
            curl -s -X POST "$NPM_API_URL/nginx/certificates" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d @-)

    CERTIFICATE_ID=$(echo "$resp" | jq -r '.id // empty')
    if [[ -n "$CERTIFICATE_ID" ]]; then
        log "Cert LE creato (ID: $CERTIFICATE_ID)."
    else
        # Senza certificato gli host andrebbero online in HTTP semplice (login di Portainer in chiaro):
        # meglio fermarsi, ad esempio se il DNS non si è ancora propagato, e rilanciare.
        log "ERRORE: richiesta LE fallita: $resp"
        CERTIFICATE_ID=0
        return 1
    fi
}

create_local_certificate() {
    jq -e '.localCertificate' "$DESCRIPTOR" &>/dev/null || { log "localCertificate assente, skip."; return 0; }

    local enabled name domains resp
    enabled=$(jq -r '.localCertificate.enabled // false' "$DESCRIPTOR")
    [[ "$enabled" != "true" ]] && { log "localCertificate disabilitato, skip."; return 0; }
    name=$(jq -r '.localCertificate.name // "local-cert"' "$DESCRIPTOR")

    # Già esistente?
    local existing_id
    existing_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$NPM_API_URL/nginx/certificates" | \
        jq -r ".[] | select(.nice_name==\"$name\") | .id // empty" | head -1) || true
    [[ -n "$existing_id" ]] && { log "Cert locale '$name' già presente (ID: $existing_id)."; CERTIFICATE_ID="$existing_id"; return 0; }

    domains=$(jq -c '.localCertificate.domains' "$DESCRIPTOR")
    domains=$(resolve_domains "$domains")
    log "Creazione cert locale '$name' per: $(echo "$domains" | jq -r 'join(", ")') ..."

    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache openssl
        fi
    fi

    local tmp_dir cert_path key_path
    tmp_dir=$(mktemp -d)
    cert_path="$tmp_dir/cert.pem"
    key_path="$tmp_dir/key.pem"

    if ! openssl req -x509 -nodes -newkey rsa:2048 \
        -days 365 \
        -subj "/CN=$(echo "$domains" | jq -r '.[0]')" \
        -addext "subjectAltName=$(echo "$domains" | jq -r 'map("DNS:" + .) | join(",")')" \
        -keyout "$key_path" -out "$cert_path" >/dev/null 2>&1; then
        log "ERRORE: openssl non è riuscito a generare il certificato locale."
        rm -rf "$tmp_dir"
        CERTIFICATE_ID=0
        return 1
    fi

    # Step 1: crea il record certificato (provider "other").
    resp=$(jq -n --arg name "$name" --argjson domains "$domains" \
            '{nice_name:$name, provider:"other", domain_names:$domains}' | \
            curl -s -X POST "$NPM_API_URL/nginx/certificates" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d @-)

    CERTIFICATE_ID=$(echo "$resp" | jq -r '.id // empty')
    if [[ -z "$CERTIFICATE_ID" ]]; then
        log "ERRORE creazione cert locale: $resp"
        rm -rf "$tmp_dir"
        CERTIFICATE_ID=0
        return 1
    fi

    # Step 2: carica i file cert/key sul record appena creato (endpoint dedicato).
    resp=$(curl -s -X POST "$NPM_API_URL/nginx/certificates/$CERTIFICATE_ID/upload" \
        -H "Authorization: Bearer $TOKEN" \
        -F "certificate=@${cert_path};type=text/plain" \
        -F "certificate_key=@${key_path};type=text/plain")
    rm -rf "$tmp_dir"

    if echo "$resp" | jq -e '.certificate' &>/dev/null; then
        log "Cert locale creato e caricato (ID: $CERTIFICATE_ID)."
    else
        log "ERRORE upload cert locale: $resp"
        CERTIFICATE_ID=0
        return 1
    fi
}

create_custom_certificate() {
    local name domains cert key intermediate
    name=$(jq -r '.serverCertificate.name // "custom-cert"' "$DESCRIPTOR")

    local existing_id
    existing_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$NPM_API_URL/nginx/certificates" | \
        jq -r ".[] | select(.nice_name==\"$name\") | .id // empty" | head -1) || true
    [[ -n "$existing_id" ]] && { log "Cert custom '$name' già presente (ID: $existing_id)."; CERTIFICATE_ID="$existing_id"; return 0; }

    domains=$(jq -c '.serverCertificate.domains' "$DESCRIPTOR")
    domains=$(resolve_domains "$domains")
    cert=$(jq -r '.serverCertificate.certificate'       "$DESCRIPTOR")
    key=$(jq  -r '.serverCertificate.certificate_key'   "$DESCRIPTOR")
    intermediate=$(jq -r '.serverCertificate.intermediate_certificate // ""' "$DESCRIPTOR")

    log "Caricamento cert custom '$name' ..."
    if [[ -n "$intermediate" ]]; then
        cert=$(printf '%s\n%s' "$cert" "$intermediate")
    fi

    # Step 1: crea il record certificato (provider "other").
    local resp
    resp=$(jq -n --arg name "$name" --argjson domains "$domains" \
              '{nice_name:$name, provider:"other", domain_names:$domains}' | \
            curl -s -X POST "$NPM_API_URL/nginx/certificates" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d @-)

    CERTIFICATE_ID=$(echo "$resp" | jq -r '.id // empty')
    if [[ -z "$CERTIFICATE_ID" ]]; then
        log "ERRORE: creazione cert custom fallita: $resp"
        CERTIFICATE_ID=0
        return 1
    fi

    # Step 2: carica i file cert/key sul record appena creato (endpoint dedicato).
    local tmp_dir cert_path key_path
    tmp_dir=$(mktemp -d)
    cert_path="$tmp_dir/cert.pem"
    key_path="$tmp_dir/key.pem"
    printf '%s' "$cert" > "$cert_path"
    printf '%s' "$key" > "$key_path"

    resp=$(curl -s -X POST "$NPM_API_URL/nginx/certificates/$CERTIFICATE_ID/upload" \
        -H "Authorization: Bearer $TOKEN" \
        -F "certificate=@${cert_path};type=text/plain" \
        -F "certificate_key=@${key_path};type=text/plain")
    rm -rf "$tmp_dir"

    if echo "$resp" | jq -e '.certificate' &>/dev/null; then
        log "Cert custom caricato (ID: $CERTIFICATE_ID)."
    else
        log "ERRORE: upload cert custom fallito: $resp"
        CERTIFICATE_ID=0
        return 1
    fi
}

# =============================================================================
# SEZIONE PROXY HOSTS
# =============================================================================

# -----------------------------------------------------------------------------
# CrowdSec: auth_request globale
#   NPM include /data/nginx/custom/server_proxy.conf in fondo al server block di OGNI
#   proxy host, anche quelli creati dalla UI: il blocco CrowdSec sta lì, una volta sola,
#   invece che nell'advanced_config dei singoli host del descriptor. npm_data è montato
#   in NPM_DATA_DIR. Il blocco è delimitato da marcatori: il resto del file (eventuale
#   contenuto messo a mano) non viene toccato.
# -----------------------------------------------------------------------------
NPM_DATA_DIR="${NPM_DATA_DIR:-/npm-data}"
SERVER_PROXY_CONF="$NPM_DATA_DIR/nginx/custom/server_proxy.conf"
CROWDSEC_BEGIN="# --- CrowdSec bouncer (generato da npm-init) ---"
CROWDSEC_END="# --- fine CrowdSec ---"
SERVER_PROXY_CONF_CHANGED=0
# copia del file prima di modificarlo, per poterlo ripristinare se nginx rifiuta la modifica
SERVER_PROXY_CONF_BACKUP=""
SERVER_PROXY_CONF_BACKED_UP=0

# crowdsec_auth_snippet
#   Stampa la config nginx che chiede al bouncer CrowdSec se l'IP del client è bannato.
#   - il resolver di Docker (127.0.0.11) con proxy_pass su variabile fa risolvere
#     "cs-bouncer" a runtime: se il bouncer è giù NPM parte lo stesso e le
#     richieste falliscono (fail-closed), invece di non avviarsi con
#     "host not found in upstream".
#   - X-Forwarded-For viene sovrascritto con $remote_addr: il client non può
#     spacciarsi per un altro IP.
#   - le richieste /.well-known/acme-challenge/ sono sempre ammesse (vedi sotto).
crowdsec_auth_snippet() {
    echo "$CROWDSEC_BEGIN"
    cat <<'EOF'
location = /crowdsec-auth {
    internal;
    # Le validazioni ACME HTTP-01 (rinnovo dei certificati Let's Encrypt) non passano dal bouncer:
    # con il bouncer giù o la chiave non valida il rinnovo fallirebbe in silenzio. In una
    # sottorichiesta $request_uri è l'URI della richiesta originale.
    if ($request_uri ~ ^/\.well-known/acme-challenge/) { return 204; }
    resolver 127.0.0.11 valid=30s;
    set $crowdsec_forward_auth "@CROWDSEC_FORWARD_AUTH_URL@";
    proxy_pass $crowdsec_forward_auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-Ip $remote_addr;
}
auth_request /crowdsec-auth;
EOF
    echo "$CROWDSEC_END"
}

# backup_server_proxy_conf / restore_server_proxy_conf
#   Se nginx rifiuta il blocco appena scritto (o appena tolto) il file non può restare com'è:
#   NPM ricontrolla la config a ogni salvataggio di un host, anche dalla UI, e al riavvio
#   caricherebbe il file rifiutato. Si ripristina quindi il contenuto di prima (o si cancella il
#   file, se prima non c'era).
backup_server_proxy_conf() {
    SERVER_PROXY_CONF_BACKUP=""
    if [[ -f "$SERVER_PROXY_CONF" ]]; then
        SERVER_PROXY_CONF_BACKUP=$(mktemp) || return 1
        cp "$SERVER_PROXY_CONF" "$SERVER_PROXY_CONF_BACKUP" || return 1
    fi
    SERVER_PROXY_CONF_BACKED_UP=1
}

restore_server_proxy_conf() {
    [[ "$SERVER_PROXY_CONF_BACKED_UP" == "1" ]] || return 0
    if [[ -n "$SERVER_PROXY_CONF_BACKUP" ]]; then
        cat "$SERVER_PROXY_CONF_BACKUP" > "$SERVER_PROXY_CONF"
    else
        rm -f "$SERVER_PROXY_CONF"
    fi
    log "Ripristinato $SERVER_PROXY_CONF com'era prima."
    SERVER_PROXY_CONF_CHANGED=0
}

# apply_crowdsec_global_config
#   Allinea il blocco CrowdSec in server_proxy.conf a CROWDSEC_FORWARD_AUTH_URL: lo scrive
#   (o aggiorna) se la variabile è valorizzata, lo toglie se è vuota. Imposta
#   SERVER_PROXY_CONF_CHANGED=1 se il file è cambiato (nginx va ricaricato).
apply_crowdsec_global_config() {
    local tmp snippet
    tmp=$(mktemp)

    # contenuto attuale senza il blocco gestito da npm-init
    if [[ -f "$SERVER_PROXY_CONF" ]]; then
        awk -v b="$CROWDSEC_BEGIN" -v e="$CROWDSEC_END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
            "$SERVER_PROXY_CONF" > "$tmp"
    fi
    if [[ -n "$CROWDSEC_FORWARD_AUTH_URL" ]]; then
        snippet=$(crowdsec_auth_snippet)
        printf '%s\n' "${snippet//@CROWDSEC_FORWARD_AUTH_URL@/$CROWDSEC_FORWARD_AUTH_URL}" >> "$tmp"
    fi

    if [[ -f "$SERVER_PROXY_CONF" ]] && cmp -s "$tmp" "$SERVER_PROXY_CONF"; then
        :   # già allineato
    elif [[ ! -s "$tmp" ]]; then
        if [[ -f "$SERVER_PROXY_CONF" ]]; then
            backup_server_proxy_conf || { rm -f "$tmp"; return 1; }
            rm -f "$SERVER_PROXY_CONF" || { rm -f "$tmp"; return 1; }
            SERVER_PROXY_CONF_CHANGED=1
            log "Blocco CrowdSec rimosso da $SERVER_PROXY_CONF."
        fi
    else
        backup_server_proxy_conf || { log "ERRORE: impossibile salvare una copia di $SERVER_PROXY_CONF"; rm -f "$tmp"; return 1; }
        if ! { mkdir -p "$(dirname "$SERVER_PROXY_CONF")" && cat "$tmp" > "$SERVER_PROXY_CONF"; }; then
            log "ERRORE: impossibile scrivere $SERVER_PROXY_CONF (volume npm_data montato in $NPM_DATA_DIR?)"
            restore_server_proxy_conf
            rm -f "$tmp"
            return 1
        fi
        SERVER_PROXY_CONF_CHANGED=1
        log "Blocco CrowdSec scritto in $SERVER_PROXY_CONF."
    fi
    rm -f "$tmp"
}

create_proxy_host() {
    local host_json="$1"

    local domain_names
    domain_names=$(echo "$host_json" | jq -c '.domain_names')
    domain_names=$(resolve_domains "$domain_names")

    # Estrai tutti i campi
    local fwd_scheme fwd_host fwd_port ssl_forced hsts_enabled hsts_subdomains
    local http2_support block_exploits caching_enabled ws_upgrade trust_forwarded_proto
    local access_list_id advanced_config enabled desc_cert_id locations

    fwd_scheme=$(echo "$host_json"  | jq -r '.forward_scheme')
    fwd_host=$(echo "$host_json"    | jq -r '.forward_host')
    fwd_port=$(echo "$host_json"    | jq -r '.forward_port')
    ssl_forced=$(echo "$host_json"  | jq -r '.ssl_forced // false')
    hsts_enabled=$(echo "$host_json"| jq -r '.hsts_enabled // false')
    hsts_subdomains=$(echo "$host_json" | jq -r '.hsts_subdomains // false')
    http2_support=$(echo "$host_json"   | jq -r '.http2_support // false')
    # Default true: "//" non va bene, tratta anche false come assente.
    block_exploits=$(echo "$host_json"  | jq -r 'if .block_exploits == null then true else .block_exploits end')
    caching_enabled=$(echo "$host_json" | jq -r '.caching_enabled // false')
    ws_upgrade=$(echo "$host_json"      | jq -r '.allow_websocket_upgrade // false')
    trust_forwarded_proto=$(echo "$host_json" | jq -r '.trust_forwarded_proto // false')
    access_list_id=$(echo "$host_json"  | jq -r '.access_list_id // 0')
    advanced_config=$(echo "$host_json" | jq -r '.advanced_config // ""')
    enabled=$(echo "$host_json"         | jq -r 'if .enabled == null then true else .enabled end')
    desc_cert_id=$(echo "$host_json"    | jq -r '.certificate_id // 0')
    # Le location custom viaggiano dentro il payload dell'host (NPM non ha una route
    # /locations). La PUT sostituisce l'elenco: una location tolta dal descriptor sparisce.
    locations=$(echo "$host_json" | jq -c '[(.locations // [])[] | {path, forward_scheme, forward_host, forward_port, advanced_config: (.advanced_config // "")}]')

    # certificate_id: 0 → usa quello globale; altrimenti valore esplicito
    local cert_id_to_use="$CERTIFICATE_ID"
    [[ "$desc_cert_id" != "0" ]] && cert_id_to_use="$desc_cert_id"

    local first_domain
    first_domain=$(echo "$domain_names" | jq -r '.[0]')

    # Cerca esistente
    local existing_id
    existing_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$NPM_API_URL/nginx/proxy-hosts" | \
        jq -r ".[] | select(.domain_names | index(\"$first_domain\")) | .id // empty" | head -1) || true

    local payload
    payload=$(jq -n \
        --argjson domain_names   "$domain_names" \
        --arg     forward_scheme "$fwd_scheme" \
        --arg     forward_host   "$fwd_host" \
        --argjson forward_port   "$fwd_port" \
        --argjson ssl_forced     "$ssl_forced" \
        --argjson hsts_enabled   "$hsts_enabled" \
        --argjson hsts_subdomains "$hsts_subdomains" \
        --argjson http2_support  "$http2_support" \
        --argjson block_exploits "$block_exploits" \
        --argjson caching_enabled "$caching_enabled" \
        --argjson allow_websocket_upgrade "$ws_upgrade" \
        --argjson trust_forwarded_proto "$trust_forwarded_proto" \
        --argjson access_list_id "$access_list_id" \
        --arg     advanced_config "$advanced_config" \
        --argjson certificate_id "$cert_id_to_use" \
        --argjson enabled        "$enabled" \
        --argjson locations      "$locations" \
        '{domain_names: $domain_names, forward_scheme: $forward_scheme, forward_host: $forward_host, forward_port: $forward_port,
          ssl_forced: $ssl_forced, hsts_enabled: $hsts_enabled, hsts_subdomains: $hsts_subdomains, http2_support: $http2_support,
          block_exploits: $block_exploits, caching_enabled: $caching_enabled, allow_websocket_upgrade: $allow_websocket_upgrade,
          trust_forwarded_proto: $trust_forwarded_proto, access_list_id: $access_list_id, advanced_config: $advanced_config, certificate_id: $certificate_id, enabled: $enabled,
          locations: $locations}')

    log "DEBUG payload proxy host: $(echo "$payload" | jq -c '.')"
    local host_id resp
    if [[ -n "$existing_id" ]]; then
        log "Proxy host '$first_domain' già esistente (ID: $existing_id), update..."
        resp=$(curl -s -X PUT "$NPM_API_URL/nginx/proxy-hosts/$existing_id" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload")
    else
        log "Creazione proxy host: $(echo "$domain_names" | jq -r 'join(", ")' ) ..."
        resp=$(curl -s -X POST "$NPM_API_URL/nginx/proxy-hosts" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload")
    fi
    host_id=$(proxy_host_response_id "$resp") || return 1
    log "Proxy host OK (ID: $host_id)."
    echo "$host_id"
}

# -----------------------------------------------------------------------------
# proxy_host_response_id <risposta NPM a POST/PUT di un proxy host>
#   Stampa l'id se NPM ha salvato l'host E nginx ha accettato la config. Altrimenti
#   logga l'errore e ritorna 1: NPM non rifiuta una config nginx non valida, la salva
#   e segna l'host con meta.nginx_online=false (senza configurazione attiva). La
#   risposta alla POST ha meta vuoto, quindi lo stato si legge con una GET.
# -----------------------------------------------------------------------------
proxy_host_response_id() {
    local resp="$1" id host nginx_err
    id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        log "ERRORE salvataggio proxy host: $resp"
        return 1
    fi
    host=$(curl -s -H "Authorization: Bearer $TOKEN" "$NPM_API_URL/nginx/proxy-hosts/$id")
    if [[ "$(echo "$host" | jq -r 'if .meta.nginx_online == false then "no" else "si" end' 2>/dev/null)" == "no" ]]; then
        nginx_err=$(echo "$host" | jq -r '.meta.nginx_err // "errore sconosciuto"')
        log "ERRORE: proxy host $id salvato ma nginx rifiuta la config: $nginx_err"
        return 1
    fi
    echo "$id"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log "=== NPM Auto-Setup ==="

    [[ -z "$NPM_EMAIL" || -z "$NPM_PASSWORD" ]] && { log "ERRORE: NPM_ADMIN_EMAIL e NPM_ADMIN_PASSWORD richieste."; exit 1; }
    [[ ! -f "$DESCRIPTOR" ]] && { log "ERRORE: $DESCRIPTOR non trovato."; exit 1; }
    # L'URL finisce dentro una stringa nginx tra virgolette: solo caratteri sicuri.
    if [[ -n "$CROWDSEC_FORWARD_AUTH_URL" && ! "$CROWDSEC_FORWARD_AUTH_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
        log "ERRORE: CROWDSEC_FORWARD_AUTH_URL non valido: $CROWDSEC_FORWARD_AUTH_URL"
        exit 1
    fi
    if [[ -n "$CROWDSEC_FORWARD_AUTH_URL" ]]; then
        log "Protezione CrowdSec attiva: $CROWDSEC_FORWARD_AUTH_URL"
    else
        log "Protezione CrowdSec disattiva (CROWDSEC_FORWARD_AUTH_URL vuota)."
    fi

    wait_for_npm || exit 1
    authenticate || exit 1
    create_certificate || { log "ERRORE: certificato non disponibile: non creo i proxy host (andrebbero online senza HTTPS). Correggi il problema e rilancia npm-init."; exit 1; }

    local hosts_count i
    hosts_count=$(jq '.proxyHosts | length' "$DESCRIPTOR")
    log "Trovati $hosts_count proxy host da configurare."

    local i=0
    while (( i < hosts_count )); do
        local host_json host_id
        host_json=$(jq -c ".proxyHosts[$i]" "$DESCRIPTOR")
        echo "Found host: $host_json"
        if ! host_id=$(create_proxy_host "$host_json"); then
            log "ERRORE: creazione/aggiornamento proxy host fallita."
            exit 1
        fi
        echo "Host ID: $host_id"

        (( ++i ))
    done

    # Il blocco CrowdSec globale si scrive DOPO l'allineamento degli host: su un server già
    # installato l'advanced_config degli host contiene ancora il vecchio snippet per-host e, con
    # il file globale già presente, nginx vedrebbe due volte "location = /crowdsec-auth".
    apply_crowdsec_global_config || exit 1
    if [[ "$SERVER_PROXY_CONF_CHANGED" == "1" ]]; then
        if (( hosts_count > 0 )); then
            # NPM testa e ricarica nginx a ogni salvataggio di un host: si risalva il primo
            # (identico) perché il file appena cambiato venga verificato e caricato.
            local first_host_json
            first_host_json=$(jq -c '.proxyHosts[0]' "$DESCRIPTOR")
            log "Ricarico nginx per applicare la config globale..."
            if ! create_proxy_host "$first_host_json" > /dev/null; then
                log "ERRORE: nginx rifiuta la config globale CrowdSec (vedi sopra)."
                # NPM ha salvato l'host ma senza configurazione attiva (nginx_online=false): si
                # toglie il file rifiutato e si risalva l'host perché NPM lo riattivi.
                restore_server_proxy_conf
                create_proxy_host "$first_host_json" > /dev/null \
                    || log "ATTENZIONE: l'host non è tornato online: controllalo dalla UI di NPM."
                exit 1
            fi
        else
            log "WARN: nessun proxy host nel descriptor: riavvia il container npm per applicare la config globale."
        fi
    fi

    [[ -n "$SERVER_PROXY_CONF_BACKUP" ]] && rm -f "$SERVER_PROXY_CONF_BACKUP"
    log "=== NPM Auto-Setup completato! ==="
}

main "$@"