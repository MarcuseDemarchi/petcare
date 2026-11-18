# Relatório de Auditoria — PetCare Cloud

Achados identificados na versão anterior do projeto (K3s em sub-rede pública) e o controle aplicado
na arquitetura atual. Cada controle é **verificável** (código, pipeline ou teste).

## 1. Achados e tratamentos

| # | Achado (antes) | Severidade | Controle aplicado (depois) | Evidência |
|---|---|---|---|---|
| A1 | **Chave privada SSH (`terraform/petcare-key.pem`) versionada no Git** | Crítica | Chave removida, key pair excluído na AWS, `.gitignore` bloqueia `*.pem`; acesso a servidores apenas via SSM (sem SSH) e Gitleaks na pipeline | `git log --stat` (commit inicial) · job `secrets:gitleaks` |
| A2 | Todas as EC2 com IP público em uma única sub-rede pública | Alta | 3 camadas: pública (ALB/NAT/GitLab), privada (app), isolada (dados); app e banco sem IP público | `modules/network` |
| A3 | SSH (22) e NodePorts (30000–32767) abertos para `0.0.0.0/0` | Alta | Nenhuma regra de SSH; SGs em cadeia ALB→APP→DB; GitLab restrito a `admin_cidrs` | `modules/security` |
| A4 | Banco MongoDB sem autenticação, acessível na rede do cluster | Alta | Autenticação obrigatória, usuário da app com `readWrite` só no banco `petcare`, SG + NACL só das sub-redes de app | `modules/data/user_data.sh.tftpl` |
| A5 | Credenciais AWS estáticas (`AWS_ACCESS_KEY_ID`/`SECRET`) passadas à aplicação | Alta | Código usa a cadeia padrão do SDK → credenciais temporárias do Instance Profile (IMDSv2 obrigatório) | `backend/config/config.go` |
| A6 | Dependências com CVEs altas (gin 1.9.1, x/net 0.16, x/crypto 0.14, vite 5.1, axios 1.6) | Alta | Atualizadas (Go 1.26, gin 1.12, vite 8, react-router 7); Trivy bloqueia CVE alta/crítica | job `sca:trivy` (0 vulnerabilidades) |
| A7 | Sem WAF / sem balanceador | Alta | ALB + AWS WAF: rate limit, IP reputation, OWASP Common (XSS), SQLi, Log4j, bloqueio de `/.git` `/.env` | `modules/edge` · job `verify:producao` (SQLi → 403) |
| A8 | Sem pipeline; deploy manual por `kubectl` | Média | GitLab CI/CD com gate de testes e segurança; deploy só da `main` protegida | `.gitlab-ci.yml` |
| A9 | Sem trilha de auditoria de rede/acesso | Média | VPC Flow Logs, ALB access logs e WAF logs em S3 (criptografados, TLS obrigatório, retenção 90 dias) | `main.tf`, `modules/edge` |
| A10 | Sem backup do banco | Média | Snapshots diários do EBS (DLM, 7 dias) + IaC para recriar o ambiente (DR) | `modules/data` · README (runbook) |
| A11 | Segredos do banco em `k8s/02-secrets.yaml` (base64) | Média | Senhas geradas pelo Terraform, armazenadas como `SecureString` no SSM, lidas em tempo de deploy | `after_install.sh` |
| A12 | Containers rodando como root | Baixa | Dockerfiles com usuário não-root; API em systemd com hardening (`NoNewPrivileges`, `ProtectSystem=strict`) | `petcare-backend.service` |
| A13 | Sem cabeçalhos de segurança HTTP | Baixa | `X-Frame-Options`, `X-Content-Type-Options`, `CSP`, `Referrer-Policy`, `server_tokens off` | `deploy/config/nginx.conf` · `middleware/security.go` |

### Sobre o achado A1 (histórico do Git)
O histórico **não foi reescrito** (decisão do grupo): o repositório é privado e a chave foi revogada,
portanto o segredo exposto não concede mais acesso. O Gitleaks detecta a chave ao varrer o histórico
completo — demonstração útil na apresentação:

```bash
docker run --rm -v "$PWD":/src zricethezav/gitleaks:v8.30.1 git /src --redact   # 1 leak (commit inicial)
docker run --rm -v "$PWD":/src zricethezav/gitleaks:v8.30.1 dir /src --redact   # 0 leaks (árvore atual)
```
Na pipeline, o Gitleaks bloqueia segredos na árvore atual e em **qualquer commit novo** (MR/push).

## 2. Resultado das ferramentas (última execução)

| Ferramenta | Escopo | Resultado |
|---|---|---|
| Semgrep 1.185 (`p/default`, `p/golang`, `p/react`, `p/python`) | Código | 0 achados (730 regras, 51 arquivos) |
| Gitleaks 8.30 | Árvore atual + commits novos | 0 vazamentos |
| Trivy 0.76 (SCA) | `go.mod`, `package-lock.json` | 0 CVEs altas/críticas |
| Trivy 0.76 (pacote) | binário Go + frontend publicado | 0 CVEs altas/críticas, 0 segredos |
| Checkov 3.4 | Terraform | 216 aprovadas · 0 falhas · 50 exceções justificadas |
| `go test` | API | 6 funções de teste (validação de entrada, NoSQL injection, health checks, headers) |

## 3. Riscos aceitos (exceções justificadas)

Exceções do Checkov estão **no próprio código**, com o motivo (`#checkov:skip=ID:motivo`). Principais:

| Risco aceito | Motivo | Mitigação |
|---|---|---|
| ALB apenas HTTP (sem TLS) | Learner Lab não permite domínio/ACM | WAF na frente; tráfego interno na VPC; em conta real: ACM + listener 443 + redirect |
| Chaves gerenciadas pela AWS (não CMK) em S3/EBS/SSM | Criação de CMK não garantida no Learner Lab | Tudo criptografado em repouso (AES-256 / aws/ebs / aws/ssm) |
| Hop limit IMDS = 2 na EC2 do GitLab | Containers do Runner precisam das credenciais temporárias | IMDSv2 obrigatório; instância dedicada ao CI |
| Sem replicação entre regiões | Orçamento/escopo | DR por IaC (recriação completa) + snapshots |
| Um único nó MongoDB (sem réplica) | Orçamento | Snapshots diários; em produção real: replica set em 2 AZs ou DocumentDB |
