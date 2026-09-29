#!/usr/bin/env bash
# PreCompact hook — Agentic Knowledge OS
# Backup le transcript de session avant que Claude Code auto-compacte → permet de retrouver le contexte complet plus tard.
# Les backups vont dans thinking/transcripts-backup/YYYY-MM-DD-HHMM.txt
# Extension .txt (pas .md) : ces fichiers JSONL de plusieurs Mo faisaient planter l'indexeur d'Obsidian (boucle "indexe votre coffre", 2026-08-10)

set -euo pipefail

VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_DIR="$VAULT_ROOT/thinking/transcripts-backup"
mkdir -p "$BACKUP_DIR"

# Lire l'input JSON (peut contenir des métadonnées de session, voire le transcript lui-même selon la version CLI)
INPUT=$(cat)

TIMESTAMP=$(date +%Y-%m-%d-%H%M)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")

BACKUP_FILE="$BACKUP_DIR/${TIMESTAMP}-${SESSION_ID:0:8}.txt"

{
  echo "---"
  echo "type: transcript-backup"
  echo "timestamp: $TIMESTAMP"
  echo "session_id: $SESSION_ID"
  echo "reason: pre-compact"
  echo "---"
  echo ""
  echo "# Transcript backup — $TIMESTAMP"
  echo ""
  echo "Sauvegarde automatique avant auto-compaction Claude Code."
  echo ""
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    echo "## Transcript intégral"
    echo ""
    cat "$TRANSCRIPT_PATH"
  else
    echo "## Input hook brut (transcript_path indisponible)"
    echo ""
    echo '```json'
    echo "$INPUT"
    echo '```'
  fi
} > "$BACKUP_FILE"

echo "✓ PreCompact backup: $BACKUP_FILE" >&2

exit 0
