#!/bin/bash
# make_swap.sh (#12): dimensione del fallback dd, idempotenza, controllo degli errori.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup_swap() {
    new_sandbox
    : > "$SB/etc/fstab"
    cat > "$SB/behave/free" <<'EOS'
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:           2048         100        1500           1         400        1800"
EOS
    cat > "$SB/behave/fallocate" <<'EOS'
[[ -f "$SB/state/fallocate_fail" ]] && { echo "fallocate: failed" >&2; exit 1; }
: > "${@: -1}"
EOS
    cat > "$SB/behave/dd" <<'EOS'
for a in "$@"; do case $a in of=*) : > "${a#of=}" ;; esac; done
EOS
    cat > "$SB/behave/mkswap" <<'EOS'
[[ -f "$SB/state/mkswap_fail" ]] && { echo "mkswap: failed" >&2; exit 1; }
EOS
    cat > "$SB/behave/swapon" <<'EOS'
case "$1" in
    --show*) cat "$SB/state/active" 2> /dev/null; exit 0 ;;
    *) [[ -f "$SB/state/swapon_fail" ]] && { echo "swapon: failed" >&2; exit 1; }
       echo "$1" >> "$SB/state/active"; exit 0 ;;
esac
EOS
}
run_swap() { run_in_sandbox "$SB/src/server-setup/make_swap.sh"; }
fstab_lines() { grep -c swapfile "$SB/etc/fstab" || true; }

echo "# controllo: creazione normale"
setup_swap
run_swap
assert_eq "termina con successo" "0" "$RC"
assert_called "usa fallocate con la RAM della macchina (2048M)" '^fallocate -l 2048M '
assert_called "attiva lo swap" '^swapon .*swapfile$'
assert_eq "aggiunge la riga a fstab una volta" "1" "$(fstab_lines)"
assert_match "stampa il riepilogo finale" 'Swap setup complete' "$OUT"
run_swap
assert_eq "secondo lancio: termina con successo" "0" "$RC"
assert_eq "secondo lancio: fstab non duplicato" "1" "$(fstab_lines)"

echo "# #12: fallback dd quando fallocate non funziona"
setup_swap; : > "$SB/state/fallocate_fail"
run_swap
assert_eq "il fallback riesce" "0" "$RC"
assert_called "#12 dd scrive quanto la RAM (2048 MB)" '^dd .*count=2048( |$)'
assert_not_called "#12 non scrive sempre 4096 MB" 'count=4096'

echo "# #12: /swapfile già attivo"
setup_swap; echo "$SB/swapfile" > "$SB/state/active"; : > "$SB/swapfile"
run_swap
assert_eq "#12 termina con successo" "0" "$RC"
assert_not_called "#12 non ricrea il file (fallocate/dd fallirebbero con 'Text file busy')" '^(fallocate|dd|mkswap) '
assert_match "#12 dice che lo swap è già attivo" 'already active' "$OUT"

echo "# #12: errori di mkswap / swapon"
setup_swap; : > "$SB/state/mkswap_fail"
run_swap
assert_eq "#12 mkswap fallito: esce con errore" "1" "$RC"
assert_no_match "#12 e non dichiara che lo swap è pronto" 'Swap setup complete' "$OUT"
assert_not_called "#12 e non tenta swapon" '^swapon .*swapfile$'
assert_eq "#12 e non scrive in fstab" "0" "$(fstab_lines)"

setup_swap; : > "$SB/state/swapon_fail"
run_swap
assert_eq "#12 swapon fallito: esce con errore" "1" "$RC"
assert_no_match "#12 e non dichiara che lo swap è pronto" 'Swap setup complete' "$OUT"
assert_eq "#12 e non scrive in fstab uno swap che non funziona" "0" "$(fstab_lines)"

finish
