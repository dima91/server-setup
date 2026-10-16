#!/bin/bash
# update_info_file (#11): il file di stato non va mai lasciato mancante o a metà.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

new_sandbox
INFO_FILE_PATH="$SB/setup_info"
log() { :; }
# estrae la funzione reale da setup.sh
# shellcheck source=/dev/null
source <(sed -n '/^update_info_file()/,/^}/p' "$SS_ROOT/setup.sh")

# shellcheck disable=SC2016,SC1003  # valori di prova con $ e apici letterali
args=(olduser newuser 'p w$(touch HACKED)"\'"'" 2222 'adm,sudo' /etc/server_setup server-setup)

echo "# scrittura normale"
update_info_file "${args[@]}" 2
assert_eq "permessi 0600" "600" "$(stat -c %a "$INFO_FILE_PATH")"
# shellcheck source=/dev/null
got=$( source "$INFO_FILE_PATH"; printf '%s|%s|%s|%s' "$NEW_USER_PASSW" "$NEXT_STAGE" "$NEW_USER_GROUPS" "$OLD_USER" )
assert_eq "valori speciali riletti identici dal source" "p w\$(touch HACKED)\"\\'|2|adm,sudo|olduser" "$got"
assert_false "nessun comando eseguito dal source" test -e "$SB/HACKED"
assert_eq "nessun file temporaneo lasciato accanto" "setup_info" "$(cd "$SB" && printf '%s ' setup_info* | xargs)"

echo "# scrittura che non può essere completata (#11)"
before=$(< "$INFO_FILE_PATH")
restore() { printf '%s\n' "$before" > "$INFO_FILE_PATH"; }

# a) la sostituzione finale fallisce (es. disco pieno / filesystem in sola lettura)
mkdir -p "$SB/failbin"
printf '#!/bin/bash\nexit 1\n' > "$SB/failbin/mv"; chmod +x "$SB/failbin/mv"
( PATH="$SB/failbin:$PATH"; update_info_file "${args[@]}" 3 ) 2> /dev/null
rc=$?
assert_eq "se la sostituzione fallisce la funzione ritorna errore" "1" "$rc"
assert_eq "e il vecchio contenuto resta intatto" "$before" "$(cat "$INFO_FILE_PATH" 2> /dev/null)"

restore
# b) la scrittura si interrompe a metà (printf fallisce alla quarta riga)
(
    n=0
    # shellcheck disable=SC2317,SC2059  # sostituisce il builtin: serve il formato passato così com'è
    printf() { n=$((n + 1)); [[ $n -ge 4 ]] && return 1; builtin printf "$@"; }
    update_info_file "${args[@]}" 3
) 2> /dev/null
rc=$?
assert_eq "se la scrittura si interrompe ritorna errore" "1" "$rc"
assert_eq "e il file di stato non è troncato né perso" "$before" "$(cat "$INFO_FILE_PATH" 2> /dev/null)"
assert_eq "nessun file temporaneo rimasto dopo l'errore" "setup_info" "$(cd "$SB" && printf '%s ' setup_info* | xargs)"

echo "# numero di parametri errato"
restore
update_info_file a b c 2> /dev/null
assert_eq "con parametri sbagliati non tocca il file" "$before" "$(< "$INFO_FILE_PATH")"

finish
