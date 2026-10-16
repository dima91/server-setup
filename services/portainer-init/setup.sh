#!/bin/bash
# portainer-setup/setup.sh
# Inizializzazione automatica admin user di Portainer via API
# =============================================================================

PORTAINER_URL="${PORTAINER_URL:-http://portainer:9000}"
ADMIN_USERNAME="${PORTAINER_ADMIN_USERNAME}"
ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD}"
SETUP_TOKEN="${PORTAINER_SETUP_TOKEN}"

log() { echo "[portainer-setup] $(date '+%H:%M:%S') $*" >&2; }

# -----------------------------------------------------------------------------
wait_for_portainer() {
    log "Attendo Portainer API: $PORTAINER_URL ..."
    local max=60 count=0 code="000"
    while (( count < max )); do
        code=$(curl -s -o /dev/null -w '%{http_code}' \
            "$PORTAINER_URL/api/system/status" 2>/dev/null || echo "000")
        [[ "$code" == "200" ]] && { log "Portainer API pronta!"; return 0; }
        (( ++count ))
        sleep 3
    done
    log "ERRORE: Portainer non raggiungibile dopo ${max} tentativi (ultimo HTTP: $code)"
    # Senza admin entro 5 minuti Portainer si blocca per sicurezza e risponde 303.
    [[ "$code" == "303" ]] && log "Portainer è bloccato per timeout di sicurezza: riavvia il container 'portainer' e rilancia portainer-init."
    return 1
}

# -----------------------------------------------------------------------------
check_if_initialized() {
    log "Verifico se Portainer è già inizializzato..."
    # L'endpoint non restituisce un body JSON: risponde 204 se l'admin esiste
    # già, 404 altrimenti.
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$PORTAINER_URL/api/users/admin/check" 2>/dev/null || echo "000")
    if [[ "$code" == "204" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# -----------------------------------------------------------------------------
initialize_admin() {
    log "Creazione admin user (username: $ADMIN_USERNAME)..."
    local resp body
    local -a token_header=()

    # Il corpo è costruito con jq: virgolette e backslash nella password vanno escapati.
    body=$(jq -n --arg username "$ADMIN_USERNAME" --arg password "$ADMIN_PASSWORD" '{Username:$username, Password:$password}')

    # Portainer moderno: richiede X-Setup-Token; legacy: senza token
    [[ -n "$SETUP_TOKEN" ]] && token_header=(-H "X-Setup-Token: $SETUP_TOKEN")

    resp=$(curl -s -X POST "$PORTAINER_URL/api/users/admin/init" \
        -H "Content-Type: application/json" \
        "${token_header[@]}" \
        -d "$body")

    if echo "$resp" | jq -e '.Id' > /dev/null 2>&1; then
        log "Admin user creato con successo! (ID: $(echo "$resp" | jq -r '.Id'))"
        return 0
    else
        log "ERRORE inizializzazione: $resp"
        return 1
    fi
}

# =============================================================================
main() {
    log "=== Portainer Auto-Setup ==="

    [[ -z "$ADMIN_PASSWORD" ]] && {
        log "ERRORE: PORTAINER_ADMIN_PASSWORD richiesta."
        exit 1
    }

    wait_for_portainer || exit 1

    local initialized
    initialized=$(check_if_initialized)

    if [[ "$initialized" == "true" ]]; then
        log "Portainer già inizializzato. Nulla da fare."
        exit 0
    fi

    initialize_admin || exit 1

    log "=== Portainer Auto-Setup completato! ==="
}

main "$@"