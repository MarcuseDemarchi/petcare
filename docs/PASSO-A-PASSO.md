# Passo a passo: subir o PetCare Cloud no AWS Academy Learner Lab

Guia para qualquer integrante do grupo recriar **todo o ambiente** (rede, WAF, servidores, banco,
GitLab e pipeline) na própria conta do Learner Lab. Tempo total: **cerca de 40 minutos**, a maior parte esperando.

> Cada pessoa sobe um ambiente **independente** na própria conta. O estado do Terraform
> (`terraform.tfstate`) fica só na sua máquina e **não vai para o Git**.

---

## Parte 0: pré-requisitos (uma vez só)

Você precisa só de **Docker, Git e curl**. O Terraform e a AWS CLI rodam dentro de containers.

| Sistema | O que usar |
|---|---|
| Linux | Docker Engine + git + curl |
| Windows | **WSL 2 (Ubuntu)** + Docker Desktop com integração WSL ligada. Rode tudo **dentro do terminal do Ubuntu** |
| macOS | Docker Desktop + git (curl já vem instalado) |

Teste:
```bash
docker run --rm hello-world
```

## Parte 1: baixar o projeto e ativar as ferramentas

```bash
git clone <URL-DO-REPOSITORIO> petcare
cd petcare
git pull                                  # garanta a versão mais recente

# Ativa os comandos "terraform" e "aws" (via Docker) neste terminal
export PATH="$PWD/scripts/tools:$PATH"
terraform version                         # deve mostrar Terraform v1.14.x
```

> O `export PATH=...` vale só para o terminal aberto. Se abrir outro terminal, rode de novo
> (sempre a partir da raiz do projeto). Quem já tem Terraform instalado pode pular esse passo.

## Parte 2: credenciais do Learner Lab

1. AWS Academy → curso → **Modules → Learner Lab** → **Start Lab**. Espere a bolinha ficar **verde**.
2. Clique em **AWS Details** → ao lado de *AWS CLI* clique em **Show** e copie o bloco inteiro (`[default]` + 3 linhas).
3. Cole no arquivo de credenciais e acrescente a região:
   ```bash
   mkdir -p ~/.aws
   nano ~/.aws/credentials        # cole o bloco e adicione no final a linha: region = us-east-1
   ```
4. Teste:
   ```bash
   aws sts get-caller-identity
   ```
   Deve aparecer um `Arn` com **`assumed-role/voclabs/...`**.

> ⚠️ As credenciais **expiram quando a sessão do Lab acaba** (~4 h). Ao reiniciar o Lab, repita o passo 2.
> Nunca cole essas credenciais no Git, no WhatsApp ou em outro lugar.

## Parte 3: configurar as variáveis

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
curl -s -4 ifconfig.me ; echo            # anote o SEU IP público
nano terraform.tfvars
```

Preencha com os **seus** dados:
```hcl
aws_region         = "us-east-1"
project_name       = "petcare-cloud"
admin_cidrs        = ["SEU.IP.PUBLICO/32"]       # só esse IP acessa o GitLab
notification_email = "seu-email@unidavi.edu.br"  # recebe avisos da pipeline
```

## Parte 4: criar a infraestrutura (~10 a 15 min)

Ainda dentro da pasta `terraform`:
```bash
terraform init
terraform plan -out=tfplan            # deve mostrar ~120 recursos "to add" e nenhum erro
terraform apply tfplan
```

No fim aparecem as saídas (`app_url`, `gitlab_url` etc.). Para vê-las de novo: `terraform output`.

> Se o apply parar com erro de sessão (`ExpiredToken`), renove as credenciais (Parte 2) e rode
> `terraform apply` de novo: o Terraform continua de onde parou.

## Parte 5: confirmar o e-mail

No e-mail informado chega **"AWS Notification - Subscription Confirmation"** (veja também o spam).
Clique em **Confirm subscription**. Sem isso, os avisos de sucesso/erro da pipeline não chegam.

## Parte 6: GitLab e primeira pipeline (~15 a 20 min)

Volte para a **raiz do projeto** e rode:
```bash
cd ..
./scripts/bootstrap-gitlab.sh
```
O script espera o GitLab e o Runner ficarem prontos (vai imprimindo `.`), envia o código e
protege a branch `main`. Ao final ele mostra as URLs.

Entrar no GitLab:
- URL: `terraform -chdir=terraform output -raw gitlab_url`
- Usuário: **root**
- Senha: `terraform -chdir=terraform output -raw gitlab_root_password`
- Pipeline: projeto **petcare → Build → Pipelines**. Espere todos os estágios ficarem verdes (~10 min).

## Parte 7: verificar se tudo funcionou

```bash
APP=$(terraform -chdir=terraform output -raw app_url)

curl $APP/api/version        # {"version":"<commit>"}  -> versão publicada pela pipeline
curl $APP/health/ready       # "database":"ok"          -> app falando com o MongoDB isolado
curl -s -o /dev/null -w '%{http_code}\n' "$APP/api/pets?id=1'%20OR%20'1'='1"   # 403 -> WAF bloqueou SQLi
curl -s -o /dev/null -w '%{http_code}\n' "$APP/.env"                             # 403 -> WAF bloqueou
```
Depois abra o `$APP` no navegador e cadastre cliente, pet e agendamento.
Também deve chegar o e-mail **"[PetCare] Deploy OK"**.

Checklist completo para a apresentação: [`ROTEIRO-TESTES.md`](ROTEIRO-TESTES.md).

## Parte 8: desligar (para não gastar crédito)

```bash
terraform -chdir=terraform destroy
```
Custo com tudo ligado: **~US$ 5 a 6 por dia** do crédito do Lab. No dia da apresentação, suba tudo
(Partes 4 a 6) **uns 40 minutos antes**. Recriar do zero também é a demonstração do plano de DR.

---

## Problemas comuns

| Sintoma | Solução |
|---|---|
| `ExpiredToken` / `InvalidClientTokenId` | Sessão do Lab expirou: Parte 2 de novo e repita o comando |
| `terraform: command not found` | Rode `export PATH="$PWD/scripts/tools:$PATH"` na raiz do projeto |
| `Error: No configuration files` | Você não está na pasta `terraform` (use `cd terraform` ou `-chdir=terraform`) |
| `permission denied ... docker.sock` | Linux: `sudo usermod -aG docker $USER` e faça logout/login |
| GitLab não abre no navegador | Seu IP mudou: atualize `admin_cidrs` no `terraform.tfvars` e rode `terraform apply` |
| Bootstrap esperando mais de 25 min | Console AWS → EC2 → instância `petcare-cloud-gitlab` → **Connect → Session Manager** → `sudo tail -50 /var/log/petcare-gitlab-bootstrap.log` |
| Job `deploy:producao` falhou | Console AWS → **CodeDeploy → Deployments** → abra o deploy → *View events* |
| Erro de `AccessDenied` em algum recurso | Mande a mensagem completa no grupo. O Learner Lab bloqueia algumas APIs, e o código já contorna as conhecidas (S3 Object Lock, DLM, role do Auto Scaling) |

### Limitações do Learner Lab já tratadas no código
- **Buckets S3:** criados por uma Lambda, porque o Lab nega `s3:GetBucketObjectLockConfiguration`, usado pelo recurso padrão do Terraform.
- **Backup do MongoDB:** o Lab bloqueia o DLM, então o snapshot diário do volume (retenção de 7) é feito por uma Lambda agendada pelo EventBridge.
- **Auto Scaling:** na primeira vez em uma conta nova, a role de serviço demora alguns segundos para propagar. O Terraform não espera a capacidade, e o ASG tenta de novo sozinho.
- **IAM:** usa a `LabRole` e o `LabInstanceProfile`, porque o Lab não permite criar roles.
