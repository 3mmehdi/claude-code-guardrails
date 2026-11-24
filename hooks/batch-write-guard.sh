#!/usr/bin/env bash
# batch-write-guard.sh
# Garde-fou : bloque la création batch de 3+ nouveaux fichiers en moins de 60s
# dans le même dossier sous wiki/ ou 00_Manuel/.
#
# Force la discipline "phases avec vérif" demandée par Mehdi (2026-04-28).
# Sans ce hook : agent peut créer 7 fichiers playbooks d'un coup sans checkpoint.
#
# Trigger : PreToolUse / Write
# Comportement :
#   - Lit JSON tool_input via stdin
#   - Si Write d'un nouveau fichier .md dans wiki/ ou 00_Manuel/ :
#       - Compte les nouveaux fichiers créés depuis ce hook dans le même dir, < 60s
#       - Si seuil atteint : bloque (exit 2) avec message stderr
#   - Sinon : laisse passer (exit 0)
#
# État persisté : .claude/.batch-write-state (TSV : timestamp \t dir \t file_path)
# Auto-pruning : entrées > 60s nettoyées à chaque appel.

# -e volontairement ABSENT : les filtres ci-dessous utilisent l'idiome
# « test && exit 0 ». Sous set -e, un test faux terminerait le script avec un
# code non nul, et Claude Code lirait ce code comme un blocage.
set -uo pipefail

# Racine résolue depuis l'emplacement du script, comme les quatre autres hooks.
# Avec $(pwd), un lancement depuis un autre dossier de travail écrivait l'état
# ailleurs : la garde cessait de compter sans que rien ne le signale — exactement
# le défaut que ce dépôt documente.
VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$VAULT_ROOT/.claude/.batch-write-state"
NOW=$(date +%s)
WINDOW=60       # fenêtre en secondes
THRESHOLD=2     # max nouveaux fichiers / fenêtre / dir avant blocage

# Read tool input from stdin
INPUT=$(cat)

# Naive JSON parsing (no jq dependency — Git Bash compatible)
TOOL=$(echo "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
# Chemins Windows : le JSON porte "C:\\Users\\…" ; sans cette normalisation le filtre wiki/ ne matchait jamais
# et la garde laissait tout passer en silence (constaté le 2026-11-17, doc hooks : file_path garde ses antislashs).
FILE_PATH=$(printf '%s' "$FILE_PATH" | sed 's#\\\\#/#g; s#\\#/#g')

# Filtres : seul Write de fichier neuf dans wiki/ ou 00_Manuel/ déclenche la garde
[ "$TOOL" != "Write" ] && exit 0
[ -z "$FILE_PATH" ] && exit 0
[ -e "$FILE_PATH" ] && exit 0  # ce n'est pas une création (fichier existe déjà → modif via Write)
echo "$FILE_PATH" | grep -qE "(wiki/|00_Manuel/)" || exit 0

DIR=$(dirname "$FILE_PATH")

# Init state file si absent
mkdir -p "$VAULT_ROOT/.claude"
touch "$STATE_FILE"

# Lire l'état existant, garder seulement les entrées récentes (< WINDOW), compter pour le DIR courant
TMP=$(mktemp)
COUNT_DIR=0
while IFS=$'\t' read -r ts dir fp; do
  [ -z "$ts" ] && continue
  if [ "$ts" -gt $((NOW - WINDOW)) ] 2>/dev/null; then
    printf '%s\t%s\t%s\n' "$ts" "$dir" "$fp" >> "$TMP"
    if [ "$dir" = "$DIR" ]; then
      COUNT_DIR=$((COUNT_DIR + 1))
    fi
  fi
done < "$STATE_FILE"

# Décision : bloquer si seuil atteint
if [ "$COUNT_DIR" -ge "$THRESHOLD" ]; then
  rm -f "$TMP"
  cat >&2 <<EOF
═══════════════════════════════════════════════════════════════════
🛑 BATCH-WRITE-GUARD : création bloquée

Tu tentes de créer un $((COUNT_DIR + 1))ᵉ nouveau fichier en moins de ${WINDOW}s
dans le même dossier ($DIR), au-delà du seuil de $THRESHOLD.

Mehdi a explicitement demandé une exécution PHASÉE avec validation
intermédiaire (cf. memory feedback_no_batch_file_creation.md).

ACTIONS POSSIBLES :
  1. STOP — récap les fichiers déjà créés à Mehdi, demander OK avant
     de continuer la série (recommandé).
  2. Attendre ${WINDOW}s sans nouveau Write dans ce dossier (la garde se
     remet à zéro).
  3. Si Mehdi a explicitement levé le cap ("ok pour batch sans
     checkpoint", "lance tout d'un coup, je te fais confiance") :
     supprimer .claude/.batch-write-state pour reset le compteur.

Fichier qui aurait été créé : $FILE_PATH
═══════════════════════════════════════════════════════════════════
EOF
  exit 2
fi

# Enregistrer cette tentative + commit du nouvel état
printf '%s\t%s\t%s\n' "$NOW" "$DIR" "$FILE_PATH" >> "$TMP"
mv "$TMP" "$STATE_FILE"

exit 0
