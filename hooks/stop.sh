#!/usr/bin/env bash
# Stop hook — Agentic Knowledge OS
# S'exécute à la fin de chaque session Claude Code.
# - Rappel /compress si la session a produit > N fichiers (affichage stderr)
# - Déclenche une regénération de l'index compilé si hot.md a changé

set -euo pipefail

VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$VAULT_ROOT"

# Lire l'input JSON (contient session_id, stop_hook_active, etc.)
INPUT=$(cat)

# Détecter si la session a modifié beaucoup de fichiers wiki/ (heuristique : plus de 5 changements)
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep -c '^wiki/' || echo 0)
  if (( CHANGED > 5 )); then
    echo "💡 $CHANGED fichiers wiki/ modifiés cette session — pense à lancer \`/compress\` pour journaliser les décisions clés." >&2
  fi
fi

# Si hot.md a été modifié, régénérer l'index compilé
if [[ -f "wiki/hot.md" ]]; then
  HOT_MTIME=$(stat -c %Y "wiki/hot.md" 2>/dev/null || stat -f %m "wiki/hot.md" 2>/dev/null || echo 0)
  COMPILED="thinking/compiled-index/index.md"
  COMPILED_MTIME=0
  if [[ -f "$COMPILED" ]]; then
    COMPILED_MTIME=$(stat -c %Y "$COMPILED" 2>/dev/null || stat -f %m "$COMPILED" 2>/dev/null || echo 0)
  fi

  if (( HOT_MTIME > COMPILED_MTIME )); then
    # Si llm-wiki-compiler est installé, utiliser sa commande
    if command -v wiki-compile >/dev/null 2>&1; then
      wiki-compile >/dev/null 2>&1 || true
      echo "✓ Stop hook : index compilé régénéré via wiki-compile" >&2
    else
      # Fallback : construire un index basique manuellement
      mkdir -p "thinking/compiled-index"
      {
        echo "---"
        echo "type: compiled-index"
        echo "generated_at: $(date -Iseconds)"
        echo "generator: stop-hook-fallback"
        echo "---"
        echo ""
        echo "# Index compilé (fallback, sans wiki-compile)"
        echo ""
        echo "## Entités (wiki/entités/)"
        find "wiki/entités" -name "*.md" -not -name "_index.md" -exec basename {} .md \; 2>/dev/null | sort | sed 's/^/- [[/; s/$/]]/'
        echo ""
        echo "## Projets clients (wiki/projets/)"
        find "wiki/projets" -name "*.md" -not -name "_index.md" -exec basename {} .md \; 2>/dev/null | sort | sed 's/^/- [[/; s/$/]]/'
        echo ""
        echo "## Dernier log (top 20 lignes)"
        echo ""
        head -n 20 "wiki/log.md" 2>/dev/null || echo "_(log.md absent)_"
      } > "$COMPILED" 2>/dev/null || true
      echo "✓ Stop hook : fallback index généré → $COMPILED" >&2
    fi
  fi
fi

# Re-index QMD si des pages wiki ont été touchées cette session (détection par mtime > MARKER).
# Idempotent et incrémental : qmd update ne re-embed que les fichiers modifiés.
# Couvre le cas d'une grosse batch d'ingest mid-session : au prochain SessionStart
# l'index serait à jour, mais la passe ici garantit que les requêtes `qmd query`
# dans la prochaine session (ou par un remote agent) voient les nouvelles pages.
if command -v qmd >/dev/null 2>&1; then
  MARKER=".claude/.qmd-last-reindex"
  NEED_REINDEX=0
  if [[ ! -f "$MARKER" ]]; then
    NEED_REINDEX=1
  else
    # Chercher au moins un fichier wiki/ plus récent que le MARKER
    if find wiki -name "*.md" -newer "$MARKER" -print -quit 2>/dev/null | grep -q .; then
      NEED_REINDEX=1
    fi
  fi

  if (( NEED_REINDEX == 1 )); then
    qmd update >/dev/null 2>&1 && touch "$MARKER" || true
    echo "✓ Stop hook : QMD réindexé (pages wiki modifiées détectées)" >&2
  fi
fi

# Pousser les fichiers modifiés vers le mirror lecture-seule de pc-ai (contexte Hermes Agent).
# Incrémental (pas de rsync dispo sous Windows/Git Bash) : un marker de mtime détermine ce qui a
# changé depuis le dernier push, et un seul tar|ssh transfère tout en une connexion (préserve
# l'arborescence relative, gère espaces/accents dans les noms de fichiers sans souci de quoting).
# Best-effort : réseau down ou pc-ai injoignable → on saute, retenté au prochain Stop
# (le marker n'est touché qu'en cas de succès complet).
# ⚠ 2026-08-25 : l'échec N'EST PLUS silencieux. L'alias pc-ai-runner pointait sur l'IP LAN
# (192.168.10.217), devenue injoignable ; le hook a sauté sans un mot pendant 7 jours et
# Hermes a lu une méthodologie de prospection périmée. Désormais on alerte dès que
# l'hôte est injoignable, et l'alerte s'aggrave passé MIRROR_STALE_DAYS jours de retard.
if command -v ssh >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  MIRROR_MARKER=".claude/.vault-mirror-last-push"
  MIRROR_HOST="pc-ai-runner"
  MIRROR_DEST="~/.hermes/vault-mirror"
  MIRROR_DIRS=(wiki thinking 00_Manuel CLAUDE.md)

  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$MIRROR_HOST" "true" >/dev/null 2>&1; then
    FIND_ARGS=()
    [[ -f "$MIRROR_MARKER" ]] && FIND_ARGS=(-newer "$MIRROR_MARKER")

    CHANGED_COUNT=$(find "${MIRROR_DIRS[@]}" -type f "${FIND_ARGS[@]}" -print 2>/dev/null | wc -l)

    if (( CHANGED_COUNT > 0 )); then
      if find "${MIRROR_DIRS[@]}" -type f "${FIND_ARGS[@]}" -print0 2>/dev/null \
          | tar -cf - --null -T - 2>/dev/null \
          | ssh -o ConnectTimeout=10 "$MIRROR_HOST" "mkdir -p $MIRROR_DEST && tar -xf - -C $MIRROR_DEST" >/dev/null 2>&1; then
        touch "$MIRROR_MARKER"
        echo "✓ Stop hook : mirror vault pc-ai mis à jour ($CHANGED_COUNT fichier(s))" >&2
        # Pousser les fichiers ne suffit pas : sans reindexation, l'index qmd de pc-ai reste
        # figé et Hermes cherche dans un vault d'hier — le miroir est frais, l'index ne l'est
        # pas (constaté le 2026-08-27 : 17 h de retard, la note du matin introuvable).
        # Fire-and-forget : `qmd embed` prend plusieurs minutes, on ne bloque pas la fin de session.
        ssh -o ConnectTimeout=10 "$MIRROR_HOST"           "nohup sh -c 'qmd update && qmd embed -c vault-mirror' >/tmp/qmd-reindex.log 2>&1 &"           >/dev/null 2>&1           && echo "  ↳ réindexation qmd lancée sur $MIRROR_HOST (fond, log : /tmp/qmd-reindex.log)" >&2           || echo "⚠ Stop hook : réindexation qmd distante non lancée — Hermes cherchera dans un index périmé" >&2
      else
        echo "⚠ Stop hook : échec du push mirror vers pc-ai (réessai au prochain Stop)" >&2
      fi
    fi

    # Les regles AKOS (18 pieges + 8 reflexes) sont le savoir operationnel qui evite a
    # Hermes de refaire nos erreurs — il faut qu il puisse les CHERCHER, pas seulement
    # les lire. Or qmd n indexe pas les dossiers commencant par un point : on les pousse
    # donc sous `regles-akos/` (visible) plutot que sous `.claude/rules/`.
    # Ajoute le 2026-08-26, apres que le bot vault a signale leur absence du miroir.
    # `.raw/` etait pousse tel quel : 137 fichiers physiquement presents sur pc-ai mais
    # INTROUVABLES, qmd n indexant pas les dossiers commencant par un point (3e occurrence
    # du meme piege le 2026-08-27). On le pousse sous `sources-brutes/` — visible, donc
    # indexe — en EXCLUANT les fichiers de mots de passe : un miroir interrogeable par un
    # agent n a pas a contenir d identifiants.
    if [[ -d ".raw" ]]; then
      tar -cf - --exclude='Mot de passe.md' --transform='s|^\.raw|sources-brutes|' .raw 2>/dev/null         | ssh -o ConnectTimeout=10 "$MIRROR_HOST" "tar -xf - -C $MIRROR_DEST" >/dev/null 2>&1         || echo "⚠ Stop hook : push des sources brutes vers le mirror échoué" >&2
    fi

    if [[ -d ".claude/rules" ]]; then
      tar -cf - --transform='s|^\.claude/rules|regles-akos|' .claude/rules 2>/dev/null         | ssh -o ConnectTimeout=10 "$MIRROR_HOST" "tar -xf - -C $MIRROR_DEST" >/dev/null 2>&1         || echo "⚠ Stop hook : push des règles AKOS vers le mirror échoué" >&2
    fi

    # Le push ci-dessus n'efface rien : une note RENOMMÉE laisse son ancien nom
    # dans le miroir pour toujours, et Hermes le lit comme un fait. Le 2026-09-04,
    # deux notes d'agenda renommées produisaient chaque matin une ligne « en retard »
    # pour des événements déjà faits — impossible à faire taire en éditant le vault,
    # puisque la source lue n'était plus le vault.
    # Tourne à chaque session, même sans fichier modifié : une suppression pure ne
    # rend aucun fichier local plus récent, donc CHANGED_COUNT reste à 0.
    # Le script distant refuse d'agir sur un manifeste invraisemblable (< 200 fichiers).
    PRUNE_OUT=$(find "${MIRROR_DIRS[@]}" -type f -print0 2>/dev/null \
      | ssh -o ConnectTimeout=10 "$MIRROR_HOST" \
        "python3 \$HOME/.hermes/scripts/prune-mirror.py wiki thinking 00_Manuel" 2>/dev/null)
    [[ -n "$PRUNE_OUT" ]] && echo "  ↳ $PRUNE_OUT" >&2
  else
    # Hôte injoignable : on le DIT. Silencieux = 7 jours de dérive sans que personne le voie.
    MIRROR_STALE_DAYS=2
    if [[ -f "$MIRROR_MARKER" ]]; then
      MARKER_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$MIRROR_MARKER" 2>/dev/null || echo 0) ) / 86400 ))
    else
      MARKER_AGE_DAYS=999
    fi
    if (( MARKER_AGE_DAYS >= MIRROR_STALE_DAYS )); then
      echo "🔴 Stop hook : mirror vault pc-ai PÉRIMÉ depuis ${MARKER_AGE_DAYS} j — '$MIRROR_HOST' injoignable." >&2
      echo "   Hermes lit ~/.hermes/vault-mirror comme source de vérité (skill prospection-outbox)." >&2
      echo "   Vérifier : ssh $MIRROR_HOST true   ·   alias dans ~/.ssh/config (Tailscale, IP privée retirée pour publication)" >&2
    else
      echo "⚠ Stop hook : '$MIRROR_HOST' injoignable, push mirror sauté (retard ${MARKER_AGE_DAYS} j)" >&2
    fi
  fi
fi


# --- hot.md — garde-fou de rotation (ajouté 2026-09-01, réflexe 12) ---
# Pourquoi ici et pas dans PostToolUse : PostToolUse ne se déclenche que sur Write/Edit.
# Les éditions faites via Bash (python/sed) ne le réveillent jamais — c'est ainsi que
# 117 sections se sont accumulées sans alerte. Le Stop hook, lui, voit le fichier final.
if [[ -f "wiki/hot.md" ]]; then
  PREC_COUNT=$(grep -c '^## Précédent' "wiki/hot.md" 2>/dev/null || echo 0)
  # Collage : une date d'entrée qui suit du texte au lieu d'un en-tête de section
  # -E et non -P : 'grep -P' échoue ici ("supports only unibyte and UTF-8 locales")
  # et le '|| echo 0' aurait rendu 0 en silence — panne silencieuse classique.
  # grep étant ligne à ligne, une entrée collée = une date qui n'est PAS en début de ligne.
  GLUE_COUNT=$(grep -cE '.+20[0-9]{2}-[0-9]{2}-[0-9]{2}( \(suite\))? — ' "wiki/hot.md" 2>/dev/null || true)
  GLUE_COUNT=${GLUE_COUNT:-0}
  HOT_BYTES=$(wc -c < "wiki/hot.md" 2>/dev/null || echo 0)

  if (( PREC_COUNT > 3 )); then
    echo "⚠ Stop hook : wiki/hot.md a ${PREC_COUNT} sections '## Précédent' (max 3, réflexe 12)." >&2
    echo "   Déplacer les plus anciennes en TÊTE de wiki/meta/hot-archive-2026-09-01.md — déplacer, jamais supprimer." >&2
  fi
  if (( GLUE_COUNT > 0 )); then
    echo "🔴 Stop hook : ${GLUE_COUNT} entrée(s) COLLÉE(S) dans wiki/hot.md." >&2
    echo "   Une entrée réinsérée sans son en-tête '## Précédent' se colle à la précédente :" >&2
    echo "   le fichier grossit mais le compte de sections ne bouge plus, donc la limite ne se déclenche jamais." >&2
  fi
  if (( HOT_BYTES > 30000 )); then
    echo "⚠ Stop hook : wiki/hot.md fait ${HOT_BYTES} octets — il est injecté EN ENTIER à chaque SessionStart." >&2
  fi
fi

# --- Auto-commit du vault (chantier 12, ajouté 2026-09-02) ----------------
# LOCAL UNIQUEMENT : jamais de `git push`, jamais de remote. Le but est
# l'historique et la restauration, pas la diffusion — le vault contient des
# données clients, prospects et commerciales.
# Placé dans Stop (et non PostToolUse) pour la même raison que le garde-fou
# hot.md : PostToolUse ne voit que Write/Edit, pas les éditions via Bash.
if [[ -d ".git" ]]; then
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    # Filet de sécurité : ne jamais commiter un secret, même si le .gitignore
    # a été modifié entre-temps. On refuse le commit plutôt que d'écrire dans
    # un historique qu'on ne pourra pas nettoyer.
    LEAK=$(git status --porcelain 2>/dev/null | awk '{print $NF}'            | grep -iE 'Mot de passe|\.env$|\.pem$|\.key$|auth\.json|settings\.local' || true)
    if [[ -n "$LEAK" ]]; then
      echo "🔴 Stop hook : commit du vault ANNULÉ — fichier sensible détecté :" >&2
      echo "$LEAK" | sed 's/^/     /' >&2
      echo "   Vérifier .gitignore avant de commiter quoi que ce soit." >&2
    else
      NB=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      # cut -c4- plutôt qu'awk : un chemin contenant des espaces est rendu
      # entre guillemets par --porcelain, et awk le tronquait au dernier mot.
      APERCU=$(git status --porcelain 2>/dev/null | cut -c4- | head -4                | tr -d '"' | sed 's|.*/||' | paste -sd', ' -)
      git add -A >/dev/null 2>&1
      if git commit -q -m "auto $(date '+%Y-%m-%d %H:%M') — ${NB} fichier(s) : ${APERCU}" >/dev/null 2>&1; then
        echo "✓ Stop hook : vault commité (${NB} fichier(s))" >&2
      fi
    fi
  fi
fi

# --- Garde-fou agenda (ajoute le 2026-09-02) ---
# Verifie : coherence jour/date, jours d'envoi du playbook 11, et qu'une
# echeance annoncee dans le tableau de prospection a bien sa note dans
# wiki/agenda/. Branche ici et pas sur PostToolUse : ce dernier ne se
# declenche que sur Write/Edit, or le vault est souvent edite par des
# scripts python lances en Bash.
if [[ -f "$VAULT_ROOT/.claude/scripts/agenda-guard.py" ]]; then
  PY=$(command -v python3 || command -v python)
  if [[ -n "$PY" ]]; then
    "$PY" "$VAULT_ROOT/.claude/scripts/agenda-guard.py" 2>&1 >/dev/null | sed 's/^/&/' >&2 || true
  fi
fi


exit 0
