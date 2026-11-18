#!/bin/bash
# Gera a configuração da aplicação a partir do SSM Parameter Store.
# Nenhum segredo (ex.: senha do MongoDB) existe no Git ou no pacote ZIP:
# ele é lido em tempo de deploy com as credenciais temporárias da instância.
set -euo pipefail
source /etc/petcare/bootstrap.env   # define SSM_PREFIX e AWS_REGION (criado pelo user_data)

TMP_ENV=$(mktemp)
chmod 600 "$TMP_ENV"
echo "AWS_REGION=${AWS_REGION}" >> "$TMP_ENV"
echo "APP_PORT=8080" >> "$TMP_ENV"
echo "GIN_MODE=release" >> "$TMP_ENV"

# Cada parâmetro /<prefixo>/app/NOME vira a variável de ambiente NOME
aws ssm get-parameters-by-path --region "$AWS_REGION" --path "${SSM_PREFIX}/app" \
  --with-decryption --query 'Parameters[*].[Name,Value]' --output text |
while IFS=$'\t' read -r name value; do
  echo "${name##*/}=${value}" >> "$TMP_ENV"
done

install -o root -g petcare -m 640 "$TMP_ENV" /etc/petcare/app.env
rm -f "$TMP_ENV"

install -m 644 /opt/petcare/config/petcare-backend.service /etc/systemd/system/petcare-backend.service
install -m 644 /opt/petcare/config/nginx.conf /etc/nginx/nginx.conf
chmod 750 /opt/petcare/bin/petcare-backend
chown -R root:petcare /opt/petcare/bin
find /usr/share/nginx/petcare -type d -exec chmod 755 {} +

nginx -t
systemctl daemon-reload
