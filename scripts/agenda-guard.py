# -*- coding: utf-8 -*-
"""Garde-fou agenda — appelé par le hook Stop.

Trois contrôles déterministes, nés de trois erreurs réelles du 2026-09-02 :

  A. COHÉRENCE JOUR/DATE — « jeudi 04/09 » a été écrit 11 fois alors que le
     04/09/2026 est un vendredi. Un nom de jour à côté d'une date est
     vérifiable par calcul : aucune raison de le laisser passer.

  B. JOUR D'ENVOI VALIDE — le playbook §11 ne retient que mardi/mercredi/jeudi.
     Une relance avait été programmée un vendredi sans que personne le voie.

  C. COUVERTURE AGENDA — une échéance annoncée dans le tableau de prospection
     doit avoir sa note dans wiki/agenda/. Le tableau est pointé par le
     réflexe 10 ; l'agenda n'était pointé par RIEN, donc il dépendait de la
     mémoire. Même motif que le réflexe 11 : on consigne, et on oublie de
     rendre actionnable.

Branché sur Stop et non sur PostToolUse : PostToolUse ne se déclenche que sur
Write/Edit, or le vault est très souvent édité par des scripts python lancés
en Bash — c'est ce trou qui avait laissé hot.md gonfler à 117 sections.

Sort toujours en 0 : un garde-fou ne casse jamais une session.
"""
import datetime
import io
import os
import re
import sys

try:
    # reconfigure() n'existe pas sur les Python < 3.7 ni sur un stderr redirigé
    # vers un flux binaire. L'absence d'UTF-8 dégrade l'affichage des accents,
    # elle n'empêche pas le garde-fou de fonctionner : on continue.
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, OSError):
    pass

JOURS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
JOURS_ENVOI = {1, 2, 3}          # mardi, mercredi, jeudi (playbook §11)
FENETRE = 30                     # jours à venir pris en compte
RETRO = 7                        # jours passés, pour rattraper une échéance ratée

RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TABLEAU = os.path.join(RACINE, "wiki", "projets", "prospection",
                       "Tableau de prospection.md")
AGENDA = os.path.join(RACINE, "wiki", "agenda")

# « jeudi 04/09 », « mardi 8/9 », « vendredi 04/09/2026 »
RE_JOUR_DATE = re.compile(
    r"\b(" + "|".join(JOURS) + r")\s+(\d{1,2})/(\d{1,2})(?:/(\d{4}))?", re.I)


def lire(p):
    """Rend le contenu, ou "" si le fichier n'existe pas.

    Un fichier absent est normal (une note d'agenda peut ne pas exister) ; un
    fichier présent mais illisible ne l'est pas, et se signale. Sans cette
    distinction, « je n'ai pas pu lire » s'écrirait comme « il n'y a rien » —
    le défaut que ce dépôt documente par ailleurs.
    """
    if not os.path.exists(p):
        return ""
    try:
        return io.open(p, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("(garde-fou agenda : %s illisible — %s)"
              % (os.path.basename(p), type(e).__name__), file=sys.stderr)
        return ""


def resoudre(j, m, a, aujourd):
    """Rend une date, en devinant l'année si elle est absente."""
    if a:
        try:
            return datetime.date(int(a), int(m), int(j))
        except ValueError:
            return None
    for annee in (aujourd.year, aujourd.year + 1, aujourd.year - 1):
        try:
            d = datetime.date(annee, int(m), int(j))
        except ValueError:
            continue
        if abs((d - aujourd).days) <= 180:
            return d
    return None


def controle_jours(fichiers, aujourd):
    """A — un nom de jour écrit à côté d'une date doit correspondre."""
    faux = []
    for p in fichiers:
        for mo in RE_JOUR_DATE.finditer(lire(p)):
            nom = mo.group(1).lower()
            d = resoudre(mo.group(2), mo.group(3), mo.group(4), aujourd)
            if d is None:
                continue
            reel = JOURS[d.weekday()]
            if reel != nom:
                faux.append((os.path.relpath(p, RACINE),
                             mo.group(0).strip(), reel))
    return faux


# Un RDV n'est pas un envoi : la règle mardi/mercredi/jeudi du playbook §11
# vise la prospection sortante, pas les réunions. Un rendez-vous le vendredi
# est parfaitement normal — le signaler comme une faute rend le garde-fou
# bruyant, et un garde-fou bruyant finit ignoré (leçon de « En retard »).
RE_RDV = re.compile(r"rendez-vous|\bRDV\b|créneau|appel|visio|réunion|café",
                    re.I)


def echeances(aujourd):
    """Dates futures du tableau, avec le contexte qui les entoure.

    Rend {date: (extrait, est_un_rdv)} — le contexte sert à ne pas appliquer
    la règle des jours d'envoi à une réunion.
    """
    t = lire(TABLEAU)
    vues = {}
    for mo in RE_JOUR_DATE.finditer(t):
        d = resoudre(mo.group(2), mo.group(3), mo.group(4), aujourd)
        if not d or not (aujourd <= d <= aujourd + datetime.timedelta(days=FENETRE)):
            continue
        autour = t[max(0, mo.start() - 200):mo.end() + 200]
        rdv = bool(RE_RDV.search(autour))
        if d not in vues or rdv:
            vues[d] = (mo.group(0).strip(), rdv)
    return vues


ECHEANCES = {"livraison", "facture", "relance", "renouvellement", "rdv",
             "autre"}


def controle_echeances(aujourd):
    """D — `echeance` doit valoir une valeur du modèle _modèles/evenement.

    La colonne « Type » de « Prochains événements » (Dataview, dans
    wiki/meta/calendrier.md) affiche ce champ tel quel : une valeur inventée
    rend la ligne illisible.
    """
    faux = []
    if not os.path.isdir(AGENDA):
        return faux
    for f in sorted(os.listdir(AGENDA)):
        if not f.endswith(".md"):
            continue
        p = os.path.join(AGENDA, f)
        t = lire(p)[:1500]
        if not re.search(r"^type:\s*agenda\s*$", t, re.M):
            continue
        md = re.search(r"^date:\s*(\d{4}-\d{2}-\d{2})", t, re.M)
        if not md:
            continue
        try:
            if datetime.date.fromisoformat(md.group(1)) < aujourd:
                continue          # on ne rouvre pas le passé
        except ValueError:
            continue
        me = re.search(r"^echeance:\s*(.+)$", t, re.M)
        val = (me.group(1).strip().strip('"').strip("'") if me else "")
        if val not in ECHEANCES:
            faux.append((f, val or "(vide)"))
    return faux


def controle_cases(aujourd):
    """E — un événement proche sans case à cocher ne remonte nulle part.

    Depuis le 2026-09-02, les requêtes « Aujourd'hui / Demain / En retard »
    de wiki/meta/calendrier.md lisent tout `wiki/agenda/`. Ce sont les cases
    `- [ ]` qui remontent, pas les paragraphes : une note d'événement rédigée
    en puces reste invisible le jour venu.
    """
    muets = []
    if not os.path.isdir(AGENDA):
        return muets
    for f in sorted(os.listdir(AGENDA)):
        if not f.endswith(".md"):
            continue
        t = lire(os.path.join(AGENDA, f))
        if not re.search(r"^type:\s*agenda\s*$", t, re.M):
            continue
        md = re.search(r"^date:\s*(\d{4}-\d{2}-\d{2})", t, re.M)
        if not md:
            continue
        try:
            d = datetime.date.fromisoformat(md.group(1))
        except ValueError:
            continue
        # Fenêtre volontairement asymétrique : loin devant pour préparer,
        # un peu derrière pour rattraper. Une échéance passée sans case n'est
        # signalée nulle part — c'est ce qui a laissé filer la relance ACWA
        # Robotics du 01/09, invisible dans « Aujourd'hui » comme dans
        # « En retard ».
        if not (aujourd - datetime.timedelta(days=RETRO) <= d
                <= aujourd + datetime.timedelta(days=FENETRE)):
            continue
        if not re.search(r"^\s*- \[[ x]\]", t, re.M):
            muets.append((f, d.isoformat(), d < aujourd))
    return muets


def note_existe(d):
    if not os.path.isdir(AGENDA):
        return False
    prefixe = d.isoformat()
    for f in os.listdir(AGENDA):
        if f.startswith(prefixe) and f.endswith(".md"):
            return True
    return False


def main():
    aujourd = datetime.date.today()
    a_scanner = [TABLEAU, os.path.join(RACINE, "wiki", "hot.md")]
    if os.path.isdir(AGENDA):
        for f in os.listdir(AGENDA):
            if f.endswith(".md") and re.match(r"^\d{4}-\d{2}-\d{2}", f):
                try:
                    d = datetime.date.fromisoformat(f[:10])
                except ValueError:
                    continue
                if abs((d - aujourd).days) <= FENETRE:
                    a_scanner.append(os.path.join(AGENDA, f))

    alertes = []

    for rel, extrait, reel in controle_jours(a_scanner, aujourd):
        alertes.append("  ✗ " + rel + " : « " + extrait
                       + " » — c'est un " + reel.upper())

    for d, (extrait, rdv) in sorted(echeances(aujourd).items()):
        jour = JOURS[d.weekday()]
        if not note_existe(d):
            alertes.append("  ✗ échéance " + d.isoformat() + " (" + jour
                           + ", « " + extrait + " ») annoncée dans le tableau"
                           + " — aucune note dans wiki/agenda/")
        if d.weekday() not in JOURS_ENVOI and not rdv:
            alertes.append("  ✗ " + d.isoformat() + " est un " + jour.upper()
                           + " — hors jours d'envoi du playbook §11"
                           + " (mardi/mercredi/jeudi)")

    for f, val in controle_echeances(aujourd):
        alertes.append("  ✗ wiki/agenda/" + f + " : echeance « " + val
                       + " » hors modèle — attendu : "
                       + ", ".join(sorted(ECHEANCES)))

    for f, d, passee in controle_cases(aujourd):
        if passee:
            alertes.append("  ✗ wiki/agenda/" + f + " (" + d + ") : échéance "
                           "PASSÉE et aucune case `- [ ]` — a-t-elle été "
                           "tenue ? rien ne l'a rappelée")
        else:
            alertes.append("  ✗ wiki/agenda/" + f + " (" + d + ") : aucune "
                           "case `- [ ]` — n'apparaîtra ni dans "
                           "« Aujourd'hui » ni dans « Demain »")

    if alertes:
        sortie = ["", "⚠️  Garde-fou agenda"]
        sortie.extend(alertes)
        sortie.append("  → corriger la date, corriger `echeance`, ou créer "
                      "la note wiki/agenda/AAAA-MM-JJ-<slug>.md "
                      "(modèle : wiki/_modèles/evenement.md)")
        sortie.append("     elle apparaîtra dans « Prochains événements » "
                      "de wiki/meta/calendrier.md")
        sortie.append("")
        sys.stderr.write("\n".join(sortie) + "\n")


try:
    main()
except Exception as e:
    sys.stderr.write("(garde-fou agenda inactif : " + type(e).__name__ + ")\n")
sys.exit(0)
