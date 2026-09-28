#!/bin/sh
# Verifica la regla de autoría exclusiva (ERS RNF-12.2 / RNF-12.6) sobre un rango de commits.
#
# Uso: scripts/check-authorship.sh <rango>      p. ej. origin/main..HEAD, o HEAD para todo el historial
#
# Falla si algún commit:
#   - tiene un autor distinto de Hernan Jalabert <benabhi@gmail.com>;
#   - tiene un committer distinto (se admite "GitHub <noreply@github.com>", que firma los
#     merges hechos desde la web de GitHub);
#   - incluye trailers de coautoría o atribución ("Co-authored-by:", "Generated with …").
set -eu

EXPECTED="Hernan Jalabert <benabhi@gmail.com>"
WEB_FLOW="GitHub <noreply@github.com>"
RANGE="${1:-HEAD}"
status=0

for sha in $(git rev-list "$RANGE"); do
  author=$(git log -1 --format='%an <%ae>' "$sha")
  committer=$(git log -1 --format='%cn <%ce>' "$sha")
  short=$(git log -1 --format='%h %s' "$sha")

  if [ "$author" != "$EXPECTED" ]; then
    echo "✗ $short — autor inválido: $author" >&2
    status=1
  fi

  if [ "$committer" != "$EXPECTED" ] && [ "$committer" != "$WEB_FLOW" ]; then
    echo "✗ $short — committer inválido: $committer" >&2
    status=1
  fi

  if git log -1 --format='%B' "$sha" | grep -qiE '^co-authored-by:|generated with|noreply@anthropic\.com'; then
    echo "✗ $short — el mensaje contiene coautoría o atribución" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "✓ Autoría verificada ($RANGE)"
fi

exit "$status"
