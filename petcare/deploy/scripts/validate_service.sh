#!/bin/bash
# Valida o release antes de devolver a instância ao Target Group.
# Se falhar, o CodeDeploy marca o deploy como falho e faz rollback automático.
set -uo pipefail
EXPECTED=$(cat /opt/petcare/VERSION)
for i in $(seq 1 30); do
  LIVE=$(curl -fsS http://127.0.0.1/health 2>/dev/null || true)
  READY=$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/health/ready 2>/dev/null || true)
  if echo "$LIVE" | grep -q "\"version\":\"${EXPECTED}\"" && [ "$READY" = "200" ]; then
    echo "OK: versão ${EXPECTED} saudável e MongoDB acessível (tentativa $i)"
    curl -fsS -o /dev/null http://127.0.0.1/ && exit 0
  fi
  sleep 5
done
echo "FALHA: versão ${EXPECTED} não ficou saudável"; journalctl -u petcare-backend -n 50 --no-pager
exit 1
