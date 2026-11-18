#!/bin/bash
# Para a API antes de substituir os arquivos (ignora erro no primeiro deploy).
set -uo pipefail
systemctl stop petcare-backend 2>/dev/null || true
exit 0
