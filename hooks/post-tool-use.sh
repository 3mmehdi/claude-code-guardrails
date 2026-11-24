#!/usr/bin/env bash
# PostToolUse hook — Agentic Knowledge OS
# Valide YAML frontmatter + wikilinks après chaque Write/Edit sur un .md du vault.
# Sortie : exit 0 si OK, exit 2 + stderr si bloquant, exit 0 + stderr avertissement si non bloquant.

set -euo pipefail

VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Lire l'input JSON de Claude Code (contient tool_input.file_path)
INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
# Sans jq dans le PATH du hook, repli python (sinon le hook sortait en silence)
if [[ -z "$FILE_PATH" ]] && command -v python >/dev/null 2>&1; then
  FILE_PATH=$(echo "$INPUT" | python -c 'import sys,json;print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || echo "")
fi
# Chemins Windows (C:\Users\… ou C:/Users/…) -> /c/Users/… comme VAULT_ROOT. Sans cette conversion,
# REL_PATH ne commençait jamais par wiki/ et le hook ne validait RIEN (constaté le 2026-11-17).
if [[ -n "$FILE_PATH" ]] && command -v cygpath >/dev/null 2>&1; then
  FILE_PATH=$(cygpath -u "$FILE_PATH")
fi

# Ne traiter que les .md dans wiki/ (pas CLAUDE.md, pas .raw, pas thinking/)
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *.md ]]; then
  exit 0
fi

# Normaliser le chemin et filtrer
REL_PATH="${FILE_PATH#$VAULT_ROOT/}"

if [[ "$REL_PATH" != wiki/* ]]; then
  # Seulement valider les pages wiki
  exit 0
fi

if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

WARNINGS=()
ERRORS=()

# 1) Valider YAML frontmatter
FIRST_LINE=$(head -n 1 "$FILE_PATH" 2>/dev/null || echo "")
if [[ "$FIRST_LINE" == "---" ]]; then
  # Extraire le bloc frontmatter
  FM=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$FILE_PATH")
  # Vérifier les clés minimales recommandées (type, title au moins)
  if ! echo "$FM" | grep -qE '^type:'; then
    WARNINGS+=("Frontmatter manque la clé 'type:'")
  fi
  if ! echo "$FM" | grep -qE '^(title|title:)'; then
    WARNINGS+=("Frontmatter manque la clé 'title:'")
  fi
  # Valider que le YAML parse (si python + yaml dispo)
  if command -v python >/dev/null 2>&1; then
    if ! echo "$FM" | python -c "import sys, yaml; yaml.safe_load(sys.stdin.read())" 2>/dev/null; then
      ERRORS+=("Frontmatter YAML invalide (échec de parse)")
    fi
  fi
else
  # Pas de frontmatter — avertissement (sauf pour les index ?)
  BASENAME=$(basename "$FILE_PATH")
  if [[ "$BASENAME" != "_index.md" && "$BASENAME" != "hot.md" && "$BASENAME" != "log.md" ]]; then
    WARNINGS+=("Pas de frontmatter YAML (attendu en tête de fichier)")
  fi
fi

# 2) Valider wikilinks — chaque [[X]] doit résoudre à un fichier existant
# Extraction : on cherche [[target]] ou [[target|alias]]
LINKS=$(grep -oE '\[\[[^]|#]+' "$FILE_PATH" 2>/dev/null | sed 's/\[\[//' | sort -u || true)

if [[ -n "$LINKS" ]]; then
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    # Chercher une correspondance filename (avec ou sans chemin)
    # Le lien peut être "Filename" ou "wiki/dir/Filename"
    if [[ "$link" == */* ]]; then
      # Chemin explicite : attendre wiki/.../$link.md
      if [[ ! -f "$VAULT_ROOT/$link.md" ]]; then
        WARNINGS+=("Lien cassé : [[$link]] (fichier introuvable à $link.md)")
      fi
    else
      # Filename seul : chercher n'importe où dans wiki/
      # Tout le coffre, pas seulement wiki/ : les liens vers 00_Manuel/ ou _modèles/ sont valides
      if ! find "$VAULT_ROOT" -path "$VAULT_ROOT/.raw" -prune -o \( -name "${link}.md" -o -name "${link}.canvas" \) -print -quit 2>/dev/null | grep -q .; then
        WARNINGS+=("Lien possiblement cassé : [[$link]] (aucun fichier ${link}.md dans le coffre)")
      fi
    fi
  done <<< "$LINKS"
fi

# 3) Émettre les avertissements / erreurs
if (( ${#ERRORS[@]} > 0 )); then
  echo "❌ PostToolUse ERREUR sur $REL_PATH:" >&2
  for e in "${ERRORS[@]}"; do
    echo "   - $e" >&2
  done
  exit 2
fi

if (( ${#WARNINGS[@]} > 0 )); then
  # Un stderr en sortie 0 n'est vu par personne (doc hooks) : passer par additionalContext pour que Claude le lise
  printf '%s\n' "⚠ Validation de $REL_PATH :" "${WARNINGS[@]/#/   - }" | python -c '
import sys, json
d = sys.stdin.buffer.read().decode("utf-8", "replace")
d = "".join(c for c in d if ord(c) < 0x10000)[:9000]
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": d}}))
'
fi

exit 0
