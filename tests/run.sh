#!/bin/bash
# Esegue i test di server-setup: tests/run.sh [t_stage3 t_swap ...]  (senza argomenti: tutti).
# SS_ROOT=/percorso prova un altro albero (vedi lib.sh). Servono bash, jq, curl, python3;
# t_nginx_acme usa anche Docker (salta se manca l'immagine nginx:1.27-alpine).
cd "$(dirname "$0")" || exit 1
if [[ $# -gt 0 ]]; then tests=("$@"); else mapfile -t tests < <(printf '%s\n' t_*.sh | sed 's/\.sh$//'); fi
failed=()
for t in "${tests[@]}"; do
    echo "=== $t"
    bash "./${t%.sh}.sh" || failed+=("$t")
done
echo
if [[ ${#failed[@]} -eq 0 ]]; then echo "TUTTI I TEST OK"; else echo "FALLITI: ${failed[*]}"; exit 1; fi
