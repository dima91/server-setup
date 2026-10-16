#!/bin/bash
# #10: il blocco CrowdSec generato da npm-init (auth_request di livello server) non deve
# bloccare le validazioni ACME HTTP-01, altrimenti con il bouncer giù (o con una chiave non
# valida) il rinnovo dei certificati Let's Encrypt fallisce in silenzio.
# Usa un nginx vero in Docker (immagine nginx:1.27-alpine) con la config prodotta da npm-init.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

IMG=nginx:1.27-alpine
if ! command -v docker > /dev/null || ! docker image inspect "$IMG" > /dev/null 2>&1; then
    skip "docker o immagine $IMG non disponibili"
    finish; exit $?
fi

new_sandbox
NET="sstest-acme-$$"
docker network create "$NET" > /dev/null || { ko "creazione rete docker di prova"; finish; exit 1; }
on_exit "docker network rm '$NET' > /dev/null 2>&1"

# server_proxy.conf vero, scritto dalla funzione di npm-init
export NPM_DATA_DIR="$SB/npm-data" CROWDSEC_FORWARD_AUTH_URL="http://cs-bouncer:8080/api/v1/forwardAuth"
# shellcheck source=/dev/null
source <(sed '$d' "$SS_ROOT/services/npm-init/setup.sh")
apply_crowdsec_global_config
CONF="$NPM_DATA_DIR/nginx/custom/server_proxy.conf"
assert_true "npm-init ha generato server_proxy.conf" test -s "$CONF"

mkdir -p "$SB/srv/.well-known/acme-challenge" "$SB/custom"
echo token > "$SB/srv/.well-known/acme-challenge/tok"; echo home > "$SB/srv/index.html"
cp "$CONF" "$SB/custom/server_proxy.conf"
cat > "$SB/site.conf" <<'EOS'
events {}
http {
    error_log /dev/null;
    access_log off;
    server {
        listen 8080;
        # come il template di NPM (letsencrypt-acme-challenge.conf)
        location ^~ /.well-known/acme-challenge/ { root /srv; default_type text/plain; }
        location / { root /srv; }
        include /custom/server_proxy.conf;
    }
}
EOS
for code in 200 403; do
    cat > "$SB/stub$code.conf" <<EOS
events {}
http { access_log off; error_log /dev/null; server { listen 8080; location /api/v1/forwardAuth { return $code; } } }
EOS
done

# probe BOUNCER: "none" (assente), 200 o 403 (stub). Stampa "<codice ACME> <codice home>".
probe() {
    local stub="" site port a h
    if [[ "$1" != none ]]; then
        stub=$(docker run -d --rm --network "$NET" --network-alias cs-bouncer -v "$SB/stub$1.conf:/etc/nginx/nginx.conf:ro" "$IMG")
    fi
    site=$(docker run -d --rm --network "$NET" -p 127.0.0.1::8080 -v "$SB/site.conf:/etc/nginx/nginx.conf:ro" \
        -v "$SB/custom:/custom:ro" -v "$SB/srv:/srv:ro" "$IMG")
    port=$(docker port "$site" 8080/tcp | head -1 | sed 's/.*://')
    for _ in $(seq 1 50); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")" != 000 ]] && break
        sleep 0.2
    done
    a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:$port/.well-known/acme-challenge/tok")
    h=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:$port/")
    # shellcheck disable=SC2086  # $stub può essere vuoto
    docker rm -f "$site" $stub > /dev/null 2>&1
    echo "$a $h"
}

echo "# bouncer assente (fail-closed)"
assert_eq "#10 ACME 200, tutto il resto 500" "200 500" "$(probe none)"
echo "# bouncer che risponde 200 (IP non bannato)"
assert_eq "ACME 200, home 200" "200 200" "$(probe 200)"
echo "# bouncer che risponde 403 (IP bannato)"
assert_eq "ACME 200, home 403" "200 403" "$(probe 403)"

finish
