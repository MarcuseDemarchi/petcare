#!/usr/bin/env bash
# =============================================================================
# Bootstrap pós-terraform: envia o código ao GitLab auto-hospedado e trava a main.
#
#   1. Aguarda o GitLab (criado pelo Terraform) ficar pronto
#   2. Faz o push do repositório para root/petcare  -> dispara a 1ª pipeline (deploy)
#   3. Trava a branch main: push direto = ninguém; mudanças só via Merge Request
#
# Requisitos locais: terraform (já usado no apply), git, curl.
# Uso: ./scripts/bootstrap-gitlab.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
tfout() { terraform -chdir="$TF_DIR" output -raw "$1"; }

GITLAB_URL=$(tfout gitlab_url)
ROOT_PW=$(tfout gitlab_root_password)
TOKEN=$(tfout gitlab_bootstrap_token)
APP_URL=$(tfout app_url)
API="$GITLAB_URL/api/v4"
PROJECT="root%2Fpetcare"

echo ">> GitLab: $GITLAB_URL"
echo ">> Aguardando GitLab, Runner e projeto ficarem prontos (pode levar ~15 min no 1º boot)..."
for i in $(seq 1 120); do
  if curl -fs -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PROJECT" >/dev/null 2>&1 &&
     curl -fs -H "PRIVATE-TOKEN: $TOKEN" "$API/runners/all?status=online" | grep -q petcare-runner; then
    echo "   pronto."; break
  fi
  [ "$i" = 120 ] && { echo "ERRO: GitLab não ficou pronto. Veja /var/log/petcare-gitlab-bootstrap.log via SSM."; exit 1; }
  printf '.'; sleep 15
done

echo ">> Enviando o código para $GITLAB_URL/root/petcare ..."
cd "$ROOT_DIR"
# Credencial apenas em memória (não fica gravada no .git/config)
REMOTE="http://root:${ROOT_PW}@${GITLAB_URL#http://}/root/petcare.git"
git push "$REMOTE" HEAD:main
git remote get-url gitlab >/dev/null 2>&1 || git remote add gitlab "$GITLAB_URL/root/petcare.git"

echo ">> Travando a branch main (push direto: ninguém | merge: maintainers via MR aprovado)..."
# (repete: logo após o push o GitLab pode ainda estar processando a branch)
for i in $(seq 1 10); do
  curl -s -H "PRIVATE-TOKEN: $TOKEN" -X DELETE "$API/projects/$PROJECT/protected_branches/main" >/dev/null || true
  curl -s -H "PRIVATE-TOKEN: $TOKEN" -X POST "$API/projects/$PROJECT/protected_branches" \
    --data "name=main" --data "push_access_level=0" --data "merge_access_level=40" \
    --data "allow_force_push=false" >/dev/null || true
  if curl -fs -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$PROJECT/protected_branches/main" |
     grep -q '"push_access_levels":\[{[^]]*"access_level":0'; then
    echo "   main protegida (push direto: ninguém)."; break
  fi
  [ "$i" = 10 ] && { echo "ERRO: não foi possível proteger a main. Ajuste em Settings > Repository > Protected branches."; exit 1; }
  sleep 5
done

cat <<MSG

============================================================
 Bootstrap concluído
------------------------------------------------------------
 GitLab .....: $GITLAB_URL   (usuário: root | senha: terraform output -raw gitlab_root_password)
 Pipeline ...: $GITLAB_URL/root/petcare/-/pipelines
 Aplicação ..: $APP_URL   (disponível ao fim do job deploy:producao)

 Fluxo de trabalho a partir de agora:
   git checkout -b minha-feature && git commit ... && git push gitlab minha-feature
   -> abrir Merge Request -> pipeline de CI -> merge na main -> deploy automático
============================================================
MSG
