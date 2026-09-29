#!/usr/bin/env python3
"""Rotation de wiki/hot.md — réflexe 12.

Usage : python .claude/scripts/rotate-hot.py <fichier-contenant-la-nouvelle-entrée>

Pourquoi ce script existe : la rotation faite à la main a produit trois fois le
même défaut (entrées collées faute de réinsérer l'en-tête '## Précédent'), et une
fois la perte du bloc pointeur vers l'archive. Le compte de sections ne bougeait
alors plus, donc aucune limite ne pouvait se déclencher — c'est ainsi que 117
sections s'étaient accumulées. Doctrine du vault : 3e occurrence => outil.

Invariants garantis :
  - la nouvelle entrée devient 'Dernière mise à jour'
  - l'ancienne descend AVEC son propre en-tête '## Précédent'
  - au-delà de MAX_PREC, le surplus part en TETE de l'archive (déplacé, jamais supprimé)
  - le bloc pointeur de fin est toujours réécrit avec le compte réel
"""
import io, re, sys, datetime, pathlib

MAX_PREC = 3
ROOT = pathlib.Path(__file__).resolve().parents[2]
HOT = ROOT / "wiki" / "hot.md"
ARCH = ROOT / "wiki" / "meta" / "hot-archive-2026-09-01.md"
POINTER = re.compile(r"\n---\n\n📦 Les \*\*\d+ sections.*?\n?\Z", re.S)

def sections(txt):
    """Découpe le corps en [courant, prec1, prec2, ...] sans les en-têtes."""
    parts = re.split(r"\n## Précédent\n", txt)
    return [p.strip("\n") for p in parts]

def main():
    if len(sys.argv) != 2:
        sys.exit("usage: rotate-hot.py <fichier-nouvelle-entrée>")
    new = io.open(sys.argv[1], encoding="utf-8").read().strip("\n")
    if not new:
        sys.exit("erreur : entrée vide, rien à faire")

    s = io.open(HOT, encoding="utf-8").read()
    m = re.match(r"\A(---\n.*?\n---\n)(.*?)(## Dernière mise à jour\n)(.*)\Z", s, re.S)
    if not m:
        sys.exit("erreur : structure de hot.md inattendue")
    fm, preamb, hdr, body = m.groups()

    body = POINTER.sub("", body).rstrip("\n")
    entries = [new] + sections(body)
    garde, surplus = entries[:MAX_PREC + 1], entries[MAX_PREC + 1:]

    if surplus:
        a = io.open(ARCH, encoding="utf-8").read()
        i = a.index("\n## Précédent")
        bloc = "\n".join("## Précédent\n" + x + "\n" for x in surplus)
        io.open(ARCH, "w", encoding="utf-8").write(a[:i] + "\n" + bloc + a[i:])

    total = io.open(ARCH, encoding="utf-8").read().count("\n## Précédent")
    now = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M")
    fm = re.sub(r"^updated: .*$", "updated: " + now, fm, count=1, flags=re.M)

    out = fm + preamb + hdr + garde[0] + "\n"
    for p in garde[1:]:
        out += "\n## Précédent\n" + p + "\n"
    out += ("\n---\n\n📦 Les **%d sections « Précédent » antérieures** sont conservées "
            "intégralement dans [[wiki/meta/hot-archive-2026-09-01]].\n" % total)
    io.open(HOT, "w", encoding="utf-8").write(out)

    print("hot.md : %d 'Précédent' gardés · %d archivé(s) · archive = %d sections"
          % (len(garde) - 1, len(surplus), total))

main()
