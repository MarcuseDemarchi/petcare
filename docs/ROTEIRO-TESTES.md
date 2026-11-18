# Roteiro de Testes (antes da apresentação)

Execute na ordem depois de `terraform apply` + `./scripts/bootstrap-gitlab.sh`.
Marque cada item; se algo falhar, veja a seção **Diagnóstico** no fim.

```bash
cd terraform
APP=$(terraform output -raw app_url)
GITLAB=$(terraform output -raw gitlab_url)
```

## 1. Infraestrutura
- [ ] `terraform apply` concluiu sem erros
- [ ] E-mail de confirmação do SNS recebido e **confirmado**
- [ ] Console EC2: 4 instâncias rodando (2× app, 1× mongodb, 1× gitlab); só o GitLab tem IP público
- [ ] Console VPC: 5 sub-redes, 2 NAT Gateways, rota da sub-rede isolada **sem** `0.0.0.0/0`
- [ ] Target Group: 2 alvos `healthy`

## 2. GitLab e pipeline
- [ ] `$GITLAB` abre a tela de login (do seu IP); de outro IP/rede **não** abre
- [ ] Login `root` + `terraform output -raw gitlab_root_password`
- [ ] Admin → Runners: `petcare-runner` **online**
- [ ] Projeto `root/petcare` → Settings → Repository → Protected branches: `main` com push = *No one*
- [ ] Primeira pipeline da `main` verde (todos os estágios), incluindo `deploy:producao` e `verify:producao`
- [ ] E-mail "[PetCare] Deploy OK" recebido

## 3. Aplicação
- [ ] `curl $APP/api/version` → mostra o commit curto da pipeline
- [ ] `curl $APP/health/ready` → `"database":"ok"`
- [ ] Abrir `$APP` no navegador: cadastrar cliente, pet e agendamento; dashboard atualiza
- [ ] Concluir um agendamento → CloudWatch Logs da Lambda `petcare-cloud-processar-agendamento` mostra o evento

## 4. Segurança (demonstrações)
| Teste | Comando | Esperado |
|---|---|---|
| WAF bloqueia SQLi | `curl -s -o /dev/null -w '%{http_code}\n' "$APP/api/pets?id=1'%20OR%20'1'='1"` | `403` |
| WAF bloqueia XSS | `curl -s -o /dev/null -w '%{http_code}\n' "$APP/?q=<script>alert(1)</script>"` | `403` |
| WAF bloqueia caminho sensível | `curl -s -o /dev/null -w '%{http_code}\n' "$APP/.env"` | `403` |
| Rate limit | `for i in $(seq 1 1200); do curl -s -o /dev/null "$APP/health"; done; curl -s -o /dev/null -w '%{http_code}\n' "$APP/health"` | `403` (após ~1 min) |
| App não acessível direto | IP privado das EC2 a partir da internet | sem rota |
| Banco isolado | `aws ssm start-session --target <mongo_id>` → `curl -m 5 https://google.com` | timeout (sem internet) |
| Sem SSH | Console → SG: nenhuma regra porta 22 | ✔ |
| Logs | S3 `aws-waf-logs-*` e `petcare-cloud-logs-*` (`alb/`, `vpc-flow-logs/`) | arquivos presentes |

## 5. Gate da pipeline (alteração recusada)
Crie uma branch com um segredo falso e abra um MR:
```bash
git checkout -b teste/segredo
echo 'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"' > petcare/teste.txt
git add . && git commit -m "teste: segredo" && git push gitlab teste/segredo
```
- [ ] MR aberto → job `secrets:gitleaks` **falha** → botão de merge bloqueado
- [ ] E-mail "[PetCare] FALHA - alteracao recusada" recebido

Outros testes de gate (um por MR): quebrar um teste em `router_test.go`; adicionar
`exec.Command("sh", "-c", userInput)` no Go (Semgrep); abrir `0.0.0.0/0` na porta 22 em um SG (Checkov).

## 6. Deploy com rollback
- [ ] Altere algo visível (ex.: título em `petcare/frontend/src/App.jsx`), MR → merge → nova versão no ar
- [ ] CodeDeploy (console) mostra deploy `OneAtATime` nas 2 instâncias, sem downtime
- [ ] (Opcional) Faça `validate_service.sh` falhar (`exit 1`) → CodeDeploy faz **rollback** automático + e-mail de falha

## 7. Disaster Recovery
- [ ] `terraform destroy` e `terraform apply` + bootstrap → ambiente volta idêntico (anote o tempo = RTO)

---

## Diagnóstico
| Sintoma | Onde olhar |
|---|---|
| GitLab não sobe | SSM no GitLab → `sudo tail -100 /var/log/petcare-gitlab-bootstrap.log` |
| MongoDB não sobe | SSM no Mongo → `sudo tail -100 /var/log/petcare-mongo-bootstrap.log` |
| Deploy falha | Console CodeDeploy → Deployment → View events; na EC2: `/var/log/aws/codedeploy-agent/codedeploy-agent.log` |
| API com erro | SSM na EC2 app → `sudo journalctl -u petcare-backend -n 100` |
| `AccessDenied` no apply (DLM) | `enable_mongo_snapshots = false` no `terraform.tfvars` |
| Job de deploy sem permissão AWS | Instance Profile `LabInstanceProfile` anexado à EC2 do GitLab? |
| Sessão do Lab expirou | Reinicie o Lab, recopie credenciais; EC2 voltam sozinhas (GitLab ~5 min) |
