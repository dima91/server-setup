#!/bin/bash
# tests/lib.sh - funzioni comuni dei test di server-setup (si include con "source").
#
# I test non toccano il sistema: setup.sh viene copiato in una sandbox, con i percorsi
# assoluti (/etc, /var/log, /home, /usr/local/bin) riscritti dentro la sandbox, e i
# comandi di sistema (sudo, apt, ufw, systemctl, docker, reboot, ...) sono sostituiti da
# shim in tests/shims che registrano le chiamate in $SB/calls.log.
#
# SS_ROOT sceglie l'albero da provare (default: questo repo). Per vedere un test fallire
# sul codice vecchio: git archive <commit> | tar -x -C /tmp/vecchio; SS_ROOT=/tmp/vecchio tests/run.sh

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SS_ROOT=${SS_ROOT:-$(cd "$TESTS_DIR/.." && pwd)}
export SS_ROOT TESTS_DIR

PASS=0
FAIL=0
SKIP=0
SB=""
_CLEANUP=()

# --- esito -------------------------------------------------------------------
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
ko()   { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; shift; local l; for l in "$@"; do printf '       %s\n' "$l"; done; }
skip() { SKIP=$((SKIP + 1)); printf '  skip %s\n' "$1"; }

assert_eq() {      # descrizione atteso reale
    if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1" "atteso: $2" "reale:  $3"; fi
}
assert_match() {   # descrizione regex testo
    if [[ "$3" =~ $2 ]]; then ok "$1"; else ko "$1" "regex: $2" "testo: ${3:0:400}"; fi
}
assert_no_match() {
    if [[ "$3" =~ $2 ]]; then ko "$1" "regex non attesa: $2" "testo: ${3:0:400}"; else ok "$1"; fi
}
assert_true() {    # descrizione comando...
    local d="$1"; shift
    if "$@"; then ok "$d"; else ko "$d" "comando fallito: $*"; fi
}
assert_false() {
    local d="$1"; shift
    if "$@"; then ko "$d" "comando riuscito ma doveva fallire: $*"; else ok "$d"; fi
}

finish() {
    local n
    for n in "${_CLEANUP[@]}"; do eval "$n" 2> /dev/null; done
    printf '== %s: %d ok, %d fallite, %d saltate\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
    [[ $FAIL -eq 0 ]]
}
on_exit() { _CLEANUP+=("$1"); }
# shellcheck disable=SC2154  # _c è la variabile del ciclo dentro la stringa del trap
trap 'for _c in "${_CLEANUP[@]}"; do eval "$_c" 2> /dev/null; done' EXIT

# --- sandbox -------------------------------------------------------------------
# new_sandbox: crea $SB con shim e cartelle; copia l'albero sotto test (senza .git,
# .claude, tests e soprattutto senza il vero services/.env) in $SB/src/server-setup.
new_sandbox() {
    SB=$(mktemp -d "${TMPDIR:-/tmp}/sstest.XXXXXX")
    export SB
    on_exit "rm -rf '$SB'"
    mkdir -p "$SB"/{bin,behave,state,src,var/log,usr/local/bin,home/testuser} \
             "$SB"/etc/{ssh,default,apt/keyrings,apt/sources.list.d}
    : > "$SB/calls.log"
    local f n
    for f in "$TESTS_DIR"/shims/*; do
        n=$(basename "$f")
        install -m 0755 "$f" "$SB/bin/$n"
    done
    for n in reboot apt ufw systemctl useradd usermod chpasswd deluser hostnamectl dpkg chown \
             curl free fallocate dd mkswap swapon sleep; do
        [[ -e "$SB/bin/$n" ]] || ln -s _generic "$SB/bin/$n"
    done
    printf 'VERSION_CODENAME=bookworm\n' > "$SB/etc/os-release"
    printf '#Port 22\nPermitRootLogin yes\n' > "$SB/etc/ssh/sshd_config"
    printf 'IPV6=no\n' > "$SB/etc/default/ufw"
    mkdir -p "$SB/src/server-setup"
    tar -C "$SS_ROOT" --exclude=./.git --exclude=./.claude --exclude=./tests --exclude=./services/.env \
        -cf - . | tar -C "$SB/src/server-setup" -xf -
    transform_script "$SB/src/server-setup/setup.sh"
    [[ -f "$SB/src/server-setup/make_swap.sh" ]] && transform_script "$SB/src/server-setup/make_swap.sh"
    return 0
}

# transform_script FILE: riscrive i percorsi assoluti di sistema dentro la sandbox e
# disattiva il controllo di root (nella sandbox si gira da utente normale).
transform_script() {
    # shellcheck disable=SC2016  # \$EUID è testo da cercare, non da espandere
    sed -i \
        -e 's#\[\[ \$EUID -ne 0 \]\]#[[ 0 -ne 0 ]]#' \
        -e "s#/etc/#$SB/etc/#g" \
        -e "s#/var/log/#$SB/var/log/#g" \
        -e "s#/usr/local/bin/#$SB/usr/local/bin/#g" \
        -e "s#/home/#$SB/home/#g" \
        -e "s#/swapfile#$SB/swapfile#g" \
        "$1"
}

# install_stage_tree: simula lo stato dopo lo stage 0 (repo copiato in /etc/server_setup).
install_stage_tree() {
    mkdir -p "$SB/etc/server_setup"
    cp -r "$SB/src/server-setup" "$SB/etc/server_setup/"
}

# write_info NEXT_STAGE: scrive setup_info come farebbe update_info_file.
write_info() {
    {
        printf 'OLD_USER=%q\n' admin
        printf 'NEW_USER=%q\n' testuser
        printf 'NEW_USER_PASSW=%q\n' 'pw'
        printf 'NEW_SSH_PORT=%q\n' 2222
        printf 'NEW_USER_GROUPS=%q\n' adm
        printf 'SETUP_DATA_FOLDER=%q\n' "$SB/etc/server_setup"
        printf 'SCRIPT_DIR_NAME=%q\n' server-setup
        printf 'NEXT_STAGE=%q\n' "$1"
    } > "$SB/etc/server_setup/setup_info"
    chmod 600 "$SB/etc/server_setup/setup_info"
}

# next_stage: NEXT_STAGE salvato in setup_info
# shellcheck source=/dev/null
next_stage() { ( source "$SB/etc/server_setup/setup_info" && echo "$NEXT_STAGE" ); }

# run_in_sandbox [-i STDIN] script args...: esegue lo script con gli shim nel PATH;
# output in $SB/out.txt, codice di uscita in $RC.
# shellcheck disable=SC2034  # RC e OUT vengono letti dai test che includono questo file
run_in_sandbox() {
    local input=""
    if [[ "$1" == "-i" ]]; then input="$2"; shift 2; fi
    local script="$1"; shift
    RC=0
    ( cd "$SB" && printf '%s' "$input" | PATH="$SB/bin:$PATH" SUDO_USER="${SUDO_USER_FOR_TEST:-admin}" bash "$script" "$@" ) \
        > "$SB/out.txt" 2>&1 || RC=$?
    OUT=$(< "$SB/out.txt")
}
# shellcheck disable=SC2120  # gli argomenti sono opzionali
run_stage() { run_in_sandbox "$SB/etc/server_setup/server-setup/setup.sh" "$@"; }

calls() { cat "$SB/calls.log"; }
# assert_called DESCRIZIONE REGEX: almeno una riga di calls.log matcha (grep -E)
assert_called()     { if grep -Eq -- "$2" "$SB/calls.log"; then ok "$1"; else ko "$1" "nessuna chiamata corrisponde a: $2" "chiamate: $(tr '\n' ';' < "$SB/calls.log" | cut -c1-500)"; fi; }
assert_not_called() { if grep -Eq -- "$2" "$SB/calls.log"; then ko "$1" "chiamata non attesa: $(grep -E -- "$2" "$SB/calls.log" | head -3 | tr '\n' ';')"; else ok "$1"; fi; }
# first_line_of PATTERN: numero della prima riga di calls.log che matcha (vuoto se nessuna)
first_line_of() { grep -n -m1 -- "$1" "$SB/calls.log" | cut -d: -f1; }
count_calls() { grep -c -- "$1" "$SB/calls.log" || true; }

# make_env VARIANT: crea services/.env nell'albero di stage da example.env.
#   example  -> esattamente example.env (nessun segnaposto cambiato)
#   good     -> tutto personalizzato tranne il segnaposto NPM_DB_PASSWORD (lo cambia lo stage 3)
make_env() {
    local dst="$SB/etc/server_setup/server-setup/services/.env"
    case "$1" in
        example) cp "$SS_ROOT/services/example.env" "$dst" ;;
        good) sed -e 's/example\.com/mydomain.org/g' \
                  -e '/^NPM_DB_PASSWORD=/!s/change_me_[A-Za-z0-9_]*/Cust0mSecret9/' \
                  "$SS_ROOT/services/example.env" > "$dst" ;;
        *) echo "make_env: variante sconosciuta $1" >&2; return 1 ;;
    esac
    chmod 664 "$dst"
}
env_value() { grep -m1 "^$1=" "$2" | cut -d= -f2-; }
