#!/bin/bash
# La skill di verifica (.claude/skills/verify/SKILL.md) non deve contraddire il codice (#15).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

SKILL="$SS_ROOT/.claude/skills/verify/SKILL.md"
if [[ ! -f "$SKILL" ]]; then skip "skill di verifica assente ($SKILL)"; finish; exit $?; fi
doc=$(< "$SKILL")

# i percorsi di log che la skill dice di aspettarsi in "acquisition" devono essere quelli di acquis.yaml
acq=$(grep -o 'file:[^ `]*' "$SKILL" | head -1)
if [[ -z "$acq" ]]; then
    ko "#15 la skill indica il file di log atteso nell'acquisition" "nessun 'file:...' trovato"
elif grep -qF -- "${acq#file:/var/log/nginx}" "$SS_ROOT/services/crowdsec/acquis.yaml"; then
    ok "#15 il percorso di log della skill ($acq) è in acquis.yaml"
else
    ko "#15 il percorso di log della skill ($acq) è in acquis.yaml" "acquis.yaml: $(grep -h 'proxy-host' "$SS_ROOT/services/crowdsec/acquis.yaml")"
fi

# npm-init esce subito se il login fallisce: la skill non deve dire che prosegue
if grep -q 'authenticate || exit 1' "$SS_ROOT/services/npm-init/setup.sh"; then
    assert_no_match "#15 la skill non dice che npm-init prosegue dopo il login fallito" 'keeps going after the failed auth|cascading 404' "$doc"
else
    skip "npm-init non esce più al login fallito: controllo non applicabile"
fi
finish
