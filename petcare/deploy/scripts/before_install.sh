#!/bin/bash
# Limpa a versão anterior para evitar arquivos órfãos de outros releases.
set -euo pipefail
id petcare >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin petcare
rm -rf /opt/petcare/bin /opt/petcare/config /usr/share/nginx/petcare
mkdir -p /opt/petcare/bin /opt/petcare/config /usr/share/nginx/petcare /etc/petcare
