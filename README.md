# claude-code-guardrails

**Sept garde-fous qui empêchent un agent de coder de dériver.** Ce sont les hooks réels d'un
second cerveau Obsidian piloté par Claude Code depuis avril 2026, pas un framework.
Chacun existe parce qu'une consigne écrite n'a pas suffi.

> *Seven guardrails that keep a coding agent from drifting. These are the actual lifecycle
> hooks from a working Obsidian vault driven by Claude Code, not a framework. Each one exists
> because a written instruction failed at least twice. Code and comments are in French.*

---

## Le principe

Un agent qui écrit du code accepte les consignes et les oublie. J'ai d'abord écrit des règles,
puis j'ai constaté qu'elles se faisaient enfreindre — souvent **par moi-même dans l'heure qui
suivait leur rédaction**. La doctrine qui en est sortie tient en une ligne :

> **Si la même correction revient une troisième fois, elle ne relève plus d'une consigne mais
> d'un hook.**

Ce dépôt est la liste de ces troisièmes fois.

---

## Les garde-fous

### `hooks/stop.sh` — refuse de laisser partir un secret

```bash
LEAK=$(git status --porcelain | awk '{print $NF}' \
       | grep -iE 'Mot de passe|\.env$|\.pem$|\.key$|auth\.json|settings\.local')
```

Le `.gitignore` peut être mal écrit, contourné par un `git add -f`, ou simplement oublié quand
un fichier change de nom. Ce filet est indépendant de lui : il regarde ce qui est réellement
en partance et parle avant le commit.

### `hooks/batch-write-guard.sh` — bloque la création en série

**L'incident, 28/04/2026.** J'avais demandé de travailler « par phases avec vérifications ».
Trois heures plus tard, un « créer tout ! » de ma part a produit **7 fichiers, ~3 500 lignes,
sans un seul point de contrôle**. La consigne existait. Elle a été interprétée comme une
dispense.

Le hook compte les créations dans le même dossier et **bloque à partir du 3ᵉ fichier en moins
de 60 secondes** (`exit 2`, message sur stderr). État persisté en TSV, purgé tout seul.

### `scripts/agenda-guard.py` — vérifie ce qui est calculable

**L'incident, 02/09/2026.** « Jeudi 04/09 » écrit **onze fois**. Le 04/09/2026 est un vendredi.
Personne ne l'a vu, et la relance était en plus programmée un jour d'envoi interdit.

Trois contrôles déterministes : un nom de jour écrit à côté d'une date doit correspondre au
calendrier ; une échéance doit tomber sur un jour d'envoi valide ; une date annoncée dans un
tableau doit avoir sa note d'agenda. **Sort toujours en 0** — un garde-fou ne casse jamais une
session, il parle.

### `scripts/rotate-hot.py` — tient un invariant que la main perd

**L'incident, 01/09/2026.** Un fichier de contexte injecté en entier à chaque démarrage avait
atteint **223 Ko et 117 sections**, soit environ 55 000 tokens payés avant le premier mot.

La cause n'était pas la paresse, c'était une rotation manuelle **subtilement fausse** :
réinsérer une entrée sans son en-tête colle les sections bout à bout. Le compte ne bougeait
donc plus, et la limite ne pouvait plus se déclencher. Après outil : **6,7 Ko**.

> ⚠️ **La leçon qui dépasse ce script** : j'ai refait le collage **dans l'heure qui a suivi la
> rédaction de la règle**. C'est ce qui a fait passer le sujet de la consigne au hook.

### `hooks/post-tool-use.sh` — valide à l'écriture

Frontmatter YAML et wikilinks contrôlés après chaque `Write`/`Edit`. Un lien cassé dans un
wiki personnel ne lève aucune erreur : le clic ne fait simplement **rien**, et on ne s'en rend
compte que des mois plus tard.

> ⚠️ **Sa limite, et elle est instructive** : `PostToolUse` ne se déclenche que sur `Write` et
> `Edit`. Les éditions faites via un script Python lancé en Bash ne le réveillent **jamais** —
> c'est exactement pour ça que 117 sections ont pu s'accumuler sans une seule alerte.
> **Un garde-fou branché sur un outil ne protège que de cet outil.** Les contrôles qui doivent
> tout voir sont donc branchés sur `Stop`, pas sur `PostToolUse`.

### `hooks/pre-compact.sh` — sauvegarde avant compaction

Le transcript part dans un fichier daté avant que la fenêtre de contexte ne soit compactée.
Extension `.txt` et non `.md` : ces fichiers de plusieurs mégaoctets faisaient boucler
l'indexeur d'Obsidian (constaté le 10/08/2026).

### `hooks/session-start.sh` — injecte un contexte borné

Cache chaud, journal récent, index compilé, règles. **Borné volontairement**, parce que la
tentation inverse est celle qui a produit les 223 Ko.

---

## Ce que ce dépôt n'est pas

**Ce n'est pas un produit installable.** Les chemins pointent vers la structure de mon coffre
(`wiki/`, `00_Manuel/`, `thinking/`). Les reprendre demande de les adapter.

**Et `hooks/stop.sh` est publié allégé.** Deux retraits volontaires : une adresse IP privée dans un
message d'aide, et un bloc de synchronisation d'agenda personnel qui n'a rien à voir avec le sujet de
ce dépôt. Le reste est le fichier tel qu'il tourne.

Ce qui se reprend tel quel, en revanche, c'est la **méthode** :

1. Écrire la règle.
2. Observer qu'elle se fait enfreindre. Compter.
3. À la troisième fois, la remplacer par du code.
4. Vérifier **sur quel outil** le code est branché, parce qu'un hook ne voit que son outil.

---

## Une histoire qui résume le reste

Quatre tâches planifiées annonçaient « réussi » depuis des mois. Un lundi, des données
manquent en base sans qu'aucune alerte ne soit partie. Cause :

```bash
OUTPUT=$(collector | grep ...)
status=${PIPESTATUS[0]}
```

`PIPESTATUS` décrit la dernière **commande simple**. À l'intérieur de `$( … )` le tube s'exécute
dans un sous-shell ; de retour dans le shell parent, la dernière commande est **l'affectation
elle-même**. Mesuré : un tube nu donne `PIPESTATUS = "7 0"`, le même tube capturé par une
affectation donne `"0"`.

**Les quatre wrappers rapportaient un succès quoi qu'il arrive.** Le seul échec jamais signalé
l'avait été par accident, parce que l'étape de notification elle-même n'arrivait pas à sortir.

> Un système de supervision qui ne peut pas échouer est pire que pas de supervision, parce
> qu'il fabrique de la confiance.

Depuis, je juge une chaîne à **la présence des données attendues**, pas à l'absence d'erreurs.

---

## Licence

MIT. Voir [LICENSE](LICENSE).

## Mises à jour

- **24/11/2026** :
  - `batch-write-guard.sh` et `post-tool-use.sh` : les chemins Windows (`C:\Users\…`) sont normalisés. Sans ça, les deux gardes laissaient tout passer en silence (constaté le 17/11).
  - `post-tool-use.sh` : les avertissements passent par `additionalContext`, car un stderr en sortie 0 n'est lu par personne. Liens vérifiés dans tout le coffre, pas seulement `wiki/`.
  - `session-start.sh` : contexte découpé en quatre appels, Claude Code plafonnant chaque `additionalContext` à 10 000 caractères.
  - `stop.sh` : `qmd update` n'indexe pas les vecteurs ; `qmd embed` est lancé en fond, protégé par un verrou.
