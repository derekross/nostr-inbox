#!/bin/bash
# Embeds src/inbox.sh into widget.owl (the source inbox = cmd('…') block).
# OWL raw strings can't hold a single quote and turn \\ into \, so the script may contain neither.
set -eu
cd "$(dirname "$0")"
if grep -q "'" src/inbox.sh || grep -qF '\\' src/inbox.sh; then
  echo "src/inbox.sh: no single quotes or double backslashes allowed" >&2
  exit 1
fi
{
  awk '{print} /source inbox = cmd\(/{exit}' widget.owl
  tail -n +2 src/inbox.sh
  awk 'f{print} /^'"'"'\) every /{if(!f){print; f=1}}' widget.owl
} > widget.owl.new
mv widget.owl.new widget.owl
echo "widget.owl rebuilt"
