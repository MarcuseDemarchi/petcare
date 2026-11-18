# 🐾 PetCare Cloud

Sistema distribuído para gestão de pet shop com frontend React, backend Go, MongoDB, mensageria SNS/SQS e processamento serverless com AWS Lambda.

## Alterações realizadas

### 1. Remoção do Redis — somente MongoDB
- O Redis foi removido completamente. Não há mais container `redis` no `docker-compose.yml` nem manifesto `k8s/04-redis.yaml`.
- O backend usa exclusivamente o MongoDB para persistência e cálculo de estatísticas (stats calculadas via aggregation pipeline diretamente no MongoDB).

### 2. Integração Lambda funcionando
- O backend Go já invoca a função Lambda em dois momentos:
  - **Criação de agendamento** (`POST /api/agendamentos`): invoca a Lambda com evento `agendamento_criado`.
  - **Conclusão de agendamento** (`PUT /api/agendamentos/:id/status` com `status=concluido`): envia para a fila SQS e invoca a Lambda com evento `agendamento_concluido`.
- O código da Lambda (`lambda/index.py`) trata tanto invocações diretas quanto eventos via SQS.
- A função Lambda é configurada pela variável de ambiente `LAMBDA_FUNCTION_NAME` (padrão: `petcare-cloud-processar-agendamento`).
- Foi corrigida uma função `getEnv` duplicada no `main.go` que causava conflito de compilação.

### 3. Correção do TypeError: n.reduce is not a function (Dashboard)
- O erro ocorria no Recharts quando `chartData` continha entradas com `quantidade` indefinido ou quando `ag.servico` era `null/undefined`.
- Correções aplicadas em `frontend/src/pages/Dashboard.jsx`:
  - Todos os valores de `quantidade` são forçados para `Number(value) || 0`.
  - O nome do serviço é sanitizado com `String(name)` antes de ser usado.
  - Entradas com `quantidade === 0` são filtradas do array antes de passar ao Recharts.
  - A prop `isAnimationActive={false}` foi adicionada à `<Bar>` para evitar erros de animação com dados vazios.
  - A chave do `<Cell>` usa `key={\`cell-\${i}\`}` (evita conflito com `ag.id` que pode ser objeto MongoDB).
  - O `catch` no `Promise.all` garante que o estado `agendamentos` nunca fica como não-array.
  - `data_hora` é verificado antes de ser passado ao `format()` do date-fns.

---

## Arquitetura

```text
Frontend (React)
   ↓
Backend (Go + Gin)
   ↓
MongoDB
   ├─ Pets
   ├─ Clientes
   └─ Agendamentos

Backend → SNS (novo agendamento)
Backend → Lambda (criar/concluir agendamento)
Backend → SQS (agendamento concluído)
SQS → Lambda (trigger automático)
```

## Estrutura do projeto

```text
petcare/
├── backend/
│   ├── main.go
│   ├── go.mod
│   ├── Dockerfile
│   ├── config/config.go       # Config + AWS clients (SQS, SNS, Lambda)
│   ├── handlers/
│   │   ├── handler.go         # Struct Handler
│   │   ├── agendamentos.go    # CRUD + invocarLambda + publicarSNS/SQS
│   │   ├── clientes.go        # CRUD + GetStats (aggregation MongoDB)
│   │   └── pets.go            # CRUD
│   ├── middleware/            # logger + cabeçalhos de segurança
│   ├── router.go              # rotas (testável)
│   └── router_test.go         # testes executados na pipeline
│   └── models/models.go
├── frontend/
│   ├── src/
│   │   ├── pages/Dashboard.jsx   ← corrigido
│   │   ├── pages/Agendamentos.jsx
│   │   ├── pages/Pets.jsx
│   │   ├── pages/Clientes.jsx
│   │   ├── services/api.js
│   │   ├── App.jsx
│   │   └── main.jsx
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── vite.config.js
│   └── package.json
├── lambda/
│   └── index.py               # Handler Python: invocação direta + SQS trigger
├── deploy/                    # Pacote CodeDeploy (produção)
│   ├── appspec.yml
│   ├── scripts/               # hooks: stop, before/after install, start, validate
│   └── config/                # nginx.conf, petcare-backend.service (systemd)
├── docker-compose.yml
└── README.md
```

---

## Rotas da API

| Método | Rota | Descrição |
|--------|------|-----------|
| `GET` | `/health` | Liveness (health check do ALB) |
| `GET` | `/health/ready` | Readiness (verifica MongoDB) |
| `GET` | `/api/version` | Versão publicada (commit) |
| `GET` | `/api/pets` | Lista todos os pets |
| `POST` | `/api/pets` | Cria pet |
| `GET` | `/api/pets/:id` | Busca pet por ID |
| `PUT` | `/api/pets/:id` | Atualiza pet |
| `DELETE` | `/api/pets/:id` | Remove pet |
| `GET` | `/api/clientes` | Lista clientes |
| `POST` | `/api/clientes` | Cria cliente |
| `GET` | `/api/agendamentos` | Lista agendamentos |
| `POST` | `/api/agendamentos` | Cria agendamento → dispara Lambda + SNS |
| `GET` | `/api/agendamentos/:id` | Busca agendamento |
| `PUT` | `/api/agendamentos/:id/status` | Atualiza status → se `concluido`, dispara SQS + Lambda |
| `GET` | `/api/servicos` | Lista serviços disponíveis |
| `GET` | `/api/stats` | Estatísticas do dashboard (calculadas no MongoDB) |

---

## Variáveis de ambiente (backend)

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `APP_PORT` | `8080` | Porta do servidor |
| `MONGO_URI` | `mongodb://localhost:27017/petcare` | URI do MongoDB |
| `MONGO_DATABASE` | `petcare` | Nome do banco |
| `AWS_REGION` | `us-east-1` | Região AWS |
| `SQS_QUEUE_URL` | — | URL da fila SQS |
| `SNS_TOPIC_ARN` | — | ARN do tópico SNS |
| `LAMBDA_FUNCTION_NAME` | `petcare-cloud-processar-agendamento` | Nome da função Lambda |

> **Credenciais AWS:** a aplicação **não** aceita chaves fixas. Usa a cadeia padrão do SDK:
> em produção, o Instance Profile da EC2 (credenciais temporárias); localmente, `~/.aws/credentials`.
> Em produção as variáveis acima vêm do SSM Parameter Store (`/petcare-cloud/app/*`).

---

## Executar localmente (Docker Compose)

```bash
# Sem credenciais AWS, SNS/SQS/Lambda são apenas registrados em log
docker compose up --build
```

- Frontend: http://localhost:3000
- Backend: http://localhost:8080

---

## Deploy em produção

Feito automaticamente pela pipeline GitLab CI/CD → S3 → AWS CodeDeploy.
Veja o [README principal](../README.md).

---

## Lambda — fluxo de processamento

```
POST /api/agendamentos
  └─► backend salva no MongoDB
  └─► [goroutine] publicarEventoSNS   → SNS topic → SQS → Lambda (trigger automático)
  └─► [goroutine] invocarLambda("agendamento_criado", ...)  → Lambda direta

PUT /api/agendamentos/:id/status  { "status": "concluido" }
  └─► backend atualiza MongoDB
  └─► [goroutine] publicarFilaSQS → SQS → Lambda (trigger automático)
  └─► [goroutine] invocarLambda("agendamento_concluido", ...) → Lambda direta
```

A Lambda (`lambda/index.py`) detecta automaticamente se recebeu uma invocação direta ou um evento SQS via o campo `Records`.
