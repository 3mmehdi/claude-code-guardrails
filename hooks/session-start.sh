#!/usr/bin/env bash
# SessionStart hook — Agentic Knowledge OS
# Injecte le contexte vault dans chaque session Claude Code (hot.md, log récent, index compilé, QMD reindex si dispo).
# Sortie : JSON sur stdout avec additionalContext lu par Claude Code.

set -euo pipefail

VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$VAULT_ROOT"

HOT="wiki/hot.md"
LOG="wiki/log.md"
OVERVIEW="wiki/overview.md"
# Index compilé : priorité au nouvel output de llm-wiki-compiler (thinking/compiled-wiki/INDEX.md,
# 18 topics + 3 concepts + aliases, ~70 lignes), fallback sur l'ancien index simple produit
# par stop.sh en cas d'absence du compiler. Le gain -40 à -60 % de tokens au startup vient
# de ce switch : Claude voit le catalogue complet d'un coup au lieu de devoir re-lire wiki/index.md.
if [[ -f "thinking/compiled-wiki/INDEX.md" ]]; then
  COMPILED="thinking/compiled-wiki/INDEX.md"
  COMPILED_LABEL="compiled-wiki INDEX (llm-wiki-compiler)"
else
  COMPILED="thinking/compiled-index/index.md"
  COMPILED_LABEL="compiled-index (fallback stop-hook)"
fi

# 1) QMD update incrémental (non bloquant — silencieux si QMD n'est pas installé)
# QMD v2.x syntaxe : `qmd update` rafraîchit toutes les collections enregistrées.
if command -v qmd >/dev/null 2>&1; then
  qmd update >/dev/null 2>&1 || true
fi

# 2) Construire le contexte
CONTEXT=""

if [[ -f "$HOT" ]]; then
  CONTEXT+="## [hot.md] Cache de contexte récent\n\n$(cat "$HOT")\n\n---\n\n"
fi

if [[ -f "$OVERVIEW" ]]; then
  CONTEXT+="## [overview.md] Synthèse exécutive du vault\n\n$(cat "$OVERVIEW")\n\n---\n\n"
fi

if [[ -f "$LOG" ]]; then
  # 20 premières lignes du log (les plus récentes, car log append-only avec nouvelles entrées en haut)
  CONTEXT+="## [log.md] Dernières opérations (top 20 lignes)\n\n"
  CONTEXT+="$(head -n 20 "$LOG")\n\n---\n\n"
fi

if [[ -f "$COMPILED" ]]; then
  # Limité aux 100 premières lignes (Option B allègement) — index complet accessible via QMD à la demande
  CONTEXT+="## [$COMPILED_LABEL] Index sémantique compilé (top 100 lignes)\n\n$(head -n 100 "$COMPILED")\n\n---\n\n"
fi

# Rappel de règles clés
CONTEXT+="## [règles vault] Rappels non-négociables\n\n"
CONTEXT+="- Langue : **tout écrit dans wiki/ est en français** (CLAUDE.md). Chat peut rester en français/anglais.\n"
CONTEXT+="- \`.raw/\` est **immutable** — ne jamais modifier.\n"
CONTEXT+="- Nouvelles entrées log.md vont **en HAUT** (append-only inversé).\n"
CONTEXT+="- Commandes CPR disponibles : \`/compress\`, \`/preserve\`, \`/resume\`.\n"

# 2b) Nudge freshness-check mensuel — si le dernier audit des notebooks NotebookLM
# a plus de 30 jours (ou n'a jamais eu lieu), suggérer une passe.
# Détection : mtime du fichier le plus récent dans wiki/meta/freshness-*.md.
# `find` est sans risque pipefail (retourne 0 sans output si aucun match), contrairement à `ls`.
FRESHNESS_LATEST=$(find wiki/meta -maxdepth 1 -name "freshness-*.md" -type f 2>/dev/null | sort -r | head -1 || true)
TRIGGER_NUDGE=0
if [[ -z "$FRESHNESS_LATEST" ]]; then
  # Jamais fait — nudge uniquement si le registre notebooks.md existe (sinon pas la peine)
  if [[ -f "wiki/meta/notebooks.md" ]]; then
    TRIGGER_NUDGE=1
    NUDGE_REASON="jamais auditée"
  fi
else
  # Dernière passe > 30 jours ?
  FRESHNESS_MTIME=$(stat -c %Y "$FRESHNESS_LATEST" 2>/dev/null || stat -f %m "$FRESHNESS_LATEST" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE_DAYS=$(( (NOW - FRESHNESS_MTIME) / 86400 ))
  if (( AGE_DAYS > 30 )); then
    TRIGGER_NUDGE=1
    NUDGE_REASON="dernier audit il y a $AGE_DAYS jours"
  fi
fi

if (( TRIGGER_NUDGE == 1 )); then
  CONTEXT+="\n## [nudge] Freshness des notebooks NotebookLM\n\n"
  CONTEXT+="⏰ Fraîcheur des topics **$NUDGE_REASON** — pense à lancer \`research freshness check\` "
  CONTEXT+="(Mode 6 du skill research-pipeline) pour auditer les topics > 6 mois et décider update/archive/autoresearch.\n"
fi

# 3) Échapper le JSON proprement et émettre
# jq est utilisé si disponible (robuste avec les sauts de ligne), sinon fallback manuel.
printf '%b' "$CONTEXT" | python -c '
import sys, json
data = sys.stdin.buffer.read().decode("utf-8", "replace")
data = "".join(c for c in data if ord(c) < 0x10000)
out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": data}}
s = json.dumps(out)
sys.stdout.write(s)
'
exit 0
