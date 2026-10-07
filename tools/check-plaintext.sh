#!/usr/bin/env bash
# Vakt: varje QML-fil som visar en meddelandetext måste rendera den som ren text.
#
# Bakgrund: en SMS-kropp kommer från avsändaren. Qt:s standard för en Text är
# AutoText, som tolkar markup — marknadsplatsens granskning av DeskSMS-inlämningen
# (2026-10-01) visade att en avsändare därmed kunde få shellen att hämta en URL
# hen valde, utan att någon klickade.
#
#   bash tools/check-plaintext.sh
#
# ponytail: kontrollen är per fil, inte per Text-nod — den fångar klassen av fel
# utan en QML-parser. Byt till nodnivå om fler Text-element börjar visa kroppar.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
found=0
while IFS= read -r f; do
  found=$((found + 1))
  if grep -q "Text.PlainText" "$f"; then
    echo "ok      $f"
  else
    echo "SAKNAS  $f  — lägg till 'textFormat: Text.PlainText' där texten visas"
    fail=1
  fi
done < <(grep -rl "text: *modelData\.body" --include=*.qml . 2>/dev/null)

if [ "$found" = 0 ]; then
  echo "Ingen fil visar en meddelandetext — inget att kontrollera."
elif [ "$fail" = 0 ]; then
  echo "Plaintext-skyddet finns i alla $found fil(er) som visar meddelandetext."
fi
exit "$fail"
