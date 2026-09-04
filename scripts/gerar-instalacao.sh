#!/usr/bin/env bash
# Regera scripts/instalar.sql a partir das migrations.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Edite as migrations, não o instalar.sql." >&2
echo "Gerado a partir de $(ls supabase/migrations/*.sql | wc -l) migrations." >&2
