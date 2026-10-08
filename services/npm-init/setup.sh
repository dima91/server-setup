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
    resp=$(curl -s -X POST "$NPM_API_URL/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASSWORD\"}")
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

    # Già esistente?
    local existing_id
    existing_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "$NPM_API_URL/nginx/certificates" | \
        jq -r ".[] | select(.nice_name==\"$name\") | .id // empty" | head -1) || true
    [[ -n "$existing_id" ]] && { log "Cert LE '$name' già presente (ID: $existing_id)."; CERTIFICATE_ID="$existing_id"; return 0; }

    local metadata
    domains=$(jq -c '.localCertificate.domains' "$DESCRIPTOR")
    domains=$(resolve_domains "$domains")
    le_dns=$(jq -r '.localCertificate.letsencrypt.dns_challenge // false' "$DESCRIPTOR")

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
        log "WARN: richiesta LE fallita: $resp — proseguo senza certificato."
        CERTIFICATE_ID=0
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

    openssl req -x509 -nodes -newkey rsa:2048 \
        -days 365 \
        -subj "/CN=$(echo "$domains" | jq -r '.[0]')" \
        -addext "subjectAltName=$(echo "$domains" | jq -r 'map("DNS:" + .) | join(",")')" \
        -keyout "$key_path" -out "$cert_path" >/dev/null 2>&1

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
        return 0
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
        log "WARN: creazione cert custom fallita: $resp — proseguo senza."
        CERTIFICATE_ID=0
        return 0
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
        log "WARN: upload custom fallito: $resp — proseguo senza."
        CERTIFICATE_ID=0
    fi
}

# =============================================================================
# SEZIONE PROXY HOSTS
# =============================================================================

create_proxy_host() {
    local host_json="$1"

    local domain_names
    domain_names=$(echo "$host_json" | jq -c '.domain_names')
    domain_names=$(resolve_domains "$domain_names")

    # Estrai tutti i campi
    local fwd_scheme fwd_host fwd_port ssl_forced hsts_enabled hsts_subdomains
    local http2_support block_exploits caching_enabled ws_upgrade
    local access_list_id advanced_config enabled desc_cert_id

    fwd_scheme=$(echo "$host_json"  | jq -r '.forward_scheme')
    fwd_host=$(echo "$host_json"    | jq -r '.forward_host')
    fwd_port=$(echo "$host_json"    | jq -r '.forward_port')
    ssl_forced=$(echo "$host_json"  | jq -r '.ssl_forced // false')
    hsts_enabled=$(echo "$host_json"| jq -r '.hsts_enabled // false')
    hsts_subdomains=$(echo "$host_json" | jq -r '.hsts_subdomains // false')
    http2_support=$(echo "$host_json"   | jq -r '.http2_support // false')
    block_exploits=$(echo "$host_json"  | jq -r '.block_exploits // true')
    caching_enabled=$(echo "$host_json" | jq -r '.caching_enabled // false')
    ws_upgrade=$(echo "$host_json"      | jq -r '.allow_websocket_upgrade // false')
    access_list_id=$(echo "$host_json"  | jq -r '.access_list_id // 0')
    advanced_config=$(echo "$host_json" | jq -r '.advanced_config // ""')
    enabled=$(echo "$host_json"         | jq -r '.enabled // true')
    desc_cert_id=$(echo "$host_json"    | jq -r '.certificate_id // 0')


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
        --argjson access_list_id "$access_list_id" \
        --arg     advanced_config "$advanced_config" \
        --argjson certificate_id "$cert_id_to_use" \
        --argjson enabled        "$enabled" \
        '{domain_names: $domain_names, forward_scheme: $forward_scheme, forward_host: $forward_host, forward_port: $forward_port,
          ssl_forced: $ssl_forced, hsts_enabled: $hsts_enabled, hsts_subdomains: $hsts_subdomains, http2_support: $http2_support,
          block_exploits: $block_exploits, caching_enabled: $caching_enabled, allow_websocket_upgrade: $allow_websocket_upgrade,
          access_list_id: $access_list_id, advanced_config: $advanced_config, certificate_id: $certificate_id, enabled: $enabled}')

    log "DEBUG payload proxy host: $(echo "$payload" | jq -c '.')"
    local host_id
    if [[ -n "$existing_id" ]]; then
        log "Proxy host '$first_domain' già esistente (ID: $existing_id), update..."
        curl -s -X PUT "$NPM_API_URL/nginx/proxy-hosts/$existing_id" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null || true
        host_id="$existing_id"
    else
        log "Creazione proxy host: $(echo "$domain_names" | jq -r 'join(", ")' ) ..."
        local resp
        resp=$(curl -s -X POST "$NPM_API_URL/nginx/proxy-hosts" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload")
        host_id=$(echo "$resp" | jq -r '.id // empty')
        if [[ -z "$host_id" ]]; then
            log "ERRORE creazione proxy host: $resp"
            return 1
        fi
    fi
    log "Proxy host OK (ID: $host_id)."
    echo "$host_id"
}

# -----------------------------------------------------------------------------
create_locations() {
    local host_json="$1" proxy_host_id="$2"

    local locations count
    locations=$(echo "$host_json" | jq -c '.locations // []')
    [[ "$locations" == "[]" ]] && return 0

    count=$(echo "$locations" | jq 'length')
    log "Configurazione $count location(s) per proxy host $proxy_host_id ..."

    local i=0
    while (( i < count )); do
        local loc path fwd_scheme fwd_host fwd_port adv
        loc=$(echo "$locations" | jq -c ".[$i]")
        path=$(echo "$loc"        | jq -r '.path')
        fwd_scheme=$(echo "$loc"  | jq -r '.forward_scheme')
        fwd_host=$(echo "$loc"    | jq -r '.forward_host')
        fwd_port=$(echo "$loc"    | jq -r '.forward_port')
        adv=$(echo "$loc"         | jq -r '.advanced_config // ""')

        local existing_loc_id
        existing_loc_id=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "$NPM_API_URL/nginx/proxy-hosts/$proxy_host_id" | \
            jq -r ".locations // [] | .[] | select(.path==\"$path\") | .id // empty") || true

        local loc_payload
        loc_payload=$(jq -n --arg path "$path" --arg forward_scheme "$fwd_scheme" \
            --arg forward_host "$fwd_host" --argjson forward_port "$fwd_port" \
            --arg advanced_config "$adv" \
            '{path, forward_scheme, forward_host, forward_port, advanced_config}')

        if [[ -n "$existing_loc_id" ]]; then
            log "  Location '$path' già esistente, update..."
            curl -s -X PUT \
                "$NPM_API_URL/nginx/proxy-hosts/$proxy_host_id/locations/$existing_loc_id" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d "$loc_payload" > /dev/null || true
        else
            log "  Aggiunta location: $path -> $fwd_host:$fwd_port"
            curl -s -X POST "$NPM_API_URL/nginx/proxy-hosts/$proxy_host_id/locations" \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d "$loc_payload" > /dev/null || true
        fi

        (( ++i ))
    done
    log "Location(s) OK per host $proxy_host_id."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log "=== NPM Auto-Setup ==="

    [[ -z "$NPM_EMAIL" || -z "$NPM_PASSWORD" ]] && { log "ERRORE: NPM_ADMIN_EMAIL e NPM_ADMIN_PASSWORD richieste."; exit 1; }
    [[ ! -f "$DESCRIPTOR" ]] && { log "ERRORE: $DESCRIPTOR non trovato."; exit 1; }

    wait_for_npm
    authenticate
    create_certificate

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
        [[ -n "$host_id" ]] && create_locations "$host_json" "$host_id"
        
        (( ++i ))
    done

    log "=== NPM Auto-Setup completato! ==="
}

main "$@"