# Registro de decisões do deploy

Registro vivo do laboratório, sem segredos. Serve para retomar o trabalho sem repetir a entrevista.
Última atualização: 24/09/2026.

## Contexto confirmado

| Item | Valor | Origem |
| --- | --- | --- |
| Repositório do pipeline | `tamiriscrepalde/registro_app` (fork de `lucianoaugusto1/registro_app`), público | resposta da responsável |
| Identificador do ambiente | `lab-deploy` | resposta da responsável |
| Conta AWS / região | `083712834563` / `us-east-1` | credencial local e resposta |
| Orçamento | meta de até US$ 0,50 por ambiente e por sessão (critério de aprovação, não bloqueio) | DEPLOY.md, confirmado |
| Duração | ~2 h de uso; remoção só após confirmação explícita da responsável | DEPLOY.md, confirmado |
| Uso | até ~5 pessoas simultâneas; cadastro, login e perfil; volume de dados mínimo | hipótese aceita |
| Uploads, jobs, WebSockets, picos | nenhum | código e hipótese aceita |
| Indisponibilidade na troca de versão | aceita (o IP público da API muda a cada task) | hipótese aceita |
| Acesso | público, via HTTP sem TLS, apenas com dados sintéticos | hipótese aceita explicitamente |
| Quem confirma o encerramento | a responsável pelo ambiente | resposta |

## Escopo autorizado

Em 24/09/2026 a responsável aprovou o plano e o custo abaixo e autorizou **criar e atualizar** os recursos
do inventário para o ambiente `lab-deploy` na conta `083712834563` (`us-east-1`), pelo `scripts/deploy.sh`
e pelo pipeline. Fluxo Git: branch + PR para a `main` do fork. **A destruição não está autorizada**: exige
confirmação separada, depois que a responsável tiver usado a aplicação.

## Pendências

- **Credencial AWS**: o único perfil local (`default`) é o usuário root. Depois do alerta, a responsável
  decidiu explicitamente (24/09/2026) usar o root neste laboratório, só para o provisionamento e a remoção
  locais (`--allow-root`); o CI usa sempre a role OIDC. Alternativa não usada: a policy mínima
  [`iam-operador-lab-deploy.json`](iam-operador-lab-deploy.json), que cobre as operações do `deploy.sh` e do
  `destroy.sh` restritas aos nomes do `lab-deploy`. Recomendação: remover as access keys de root ao final.

## Fatos encontrados no código

- **API**: Node.js + Express, bcryptjs, JWT; porta 3000; health check em `GET /api/health`; lockfile npm.
- **Banco**: PostgreSQL 16; migrations versionadas em `api/migrations`, aplicadas por `node src/migrate.js`
  (transação por arquivo, tabela `schema_migrations`, sai com código 1 em falha).
- **Conexão**: `DATABASE_URL` ou `PG*`; com `DB_SSL=true` usa TLS verificado com o bundle de CA do RDS
  embutido na imagem (legível pelo usuário `node`). O RDS PostgreSQL 16 exige TLS por padrão (`rds.force_ssl=1`).
- **Frontend**: HTML/CSS/JS estático, sem bundler. Chamava `/api` relativo (proxy do nginx local).
- **Local**: `docker compose` com Postgres, API e nginx. O compose cria o schema via `docker-entrypoint-initdb.d`,
  não via `migrate.js` (diferença conhecida em relação à AWS; mantida para não alterar o fluxo local).
- **Antes deste trabalho**: sem testes, linters, workflows ou scripts de infraestrutura.
- **Consumo medido**: container da API com ~33 MiB de memória em uso (docker stats, local).

## Decisões

| Tema | Decisão | Motivo |
| --- | --- | --- |
| Compute | ECS Fargate, 1 task, 0,25 vCPU / 512 MiB, X86_64 | consumo medido ~33 MiB; imagem `linux/amd64` construída no runner x86 |
| Entrada da API | IPv4 público da task, porta 3000, sem ALB/API Gateway/NAT/domínio | restrição do laboratório |
| Rede | VPC própria `10.42.0.0/16`; 1 sub-rede pública (task) e 2 privadas (RDS) em 2 AZs | DB subnet group exige 2 AZs; `use1-az3` excluída por não ter Fargate |
| Banco | RDS PostgreSQL 16 (versão padrão da região), `db.t4g.micro`, gp3 20 GiB, Single-AZ, privado, criptografado, backup retention 0 | menor configuração compatível; dados descartáveis |
| Segredos | SSM Parameter Store SecureString (padrão, chave `aws/ssm`) para senha do banco e JWT | sem custo mensal; a task recebe via `secrets` |
| Frontend | S3 Static Website (HTTP), leitura pública só de `s3:GetObject`, ACLs bloqueadas, `Cache-Control: no-cache` | sem CloudFront; nomes de arquivo sem hash |
| URL da API no site | `config.js` gerado no deploy, depois que a task nova está saudável | IP muda a cada task |
| CORS | API libera só a origem exata do site (`CORS_ORIGIN`) | origens diferentes |
| Imagem | ECR privado com tags imutáveis (commit), scan on push, lifecycle de 10 imagens; task usa o digest | deploy consome exatamente o artefato validado |
| Migrations | task única (`run-task`) com a mesma imagem antes de trocar a versão; exit code conferido | sem acesso do runner ao RDS; não roda em cada réplica |
| Rollout | circuit breaker com rollback; espera `rolloutState` e confere se a revisão primária é a nova | o waiter `services-stable` pode retornar cedo |
| Sinais | `initProcessEnabled` na task | Node como PID 1 ignora SIGTERM e atrasaria cada rollout em 30 s |
| JWT | a API recusa iniciar sem `JWT_SECRET` | antes caía num segredo público padrão |
| CI/CD | GitHub Actions; um workflow com jobs de validação e `deploy` dependente de todos | publicação bloqueada por qualquer falha |
| Autenticação do CI | OIDC; trust só para `repo:tamiriscrepalde@22264236/registro_app@1386295906:environment:lab-deploy`, audience STS | repositório usa subject imutável; environment restrito à `main` |
| Permissões do CI | publicar em recursos existentes: ECR push, task definition, run-task, serviço, S3 do site, leitura de logs; `PassRole` só da role de execução | CI não cria/remove rede, banco, IAM nem lê segredos |
| Provisionamento | `scripts/deploy.sh --provision`, local, com a credencial da responsável (acionamento explícito) | evita dar ao CI permissões de criação de IAM |
| Estado do laboratório | variável `LAB_STATE` do repositório: `active` no provisionamento, `destroyed` no `destroy.sh` | após destruir, o pipeline só informa e não recria nada |
| Mudanças só em docs | validações rodam; publicação dispensada (`*.md`, `docs/`) | DEPLOY.md |
| Provedor OIDC | já existia na conta; reutilizado e nunca removido | recurso compartilhado |

## Verificações do CI

| Necessidade | Ferramenta |
| --- | --- |
| Instalação reproduzível | `npm ci` com `package-lock.json` (API e frontend) |
| Lint | ESLint 10 (API: Node/CommonJS; frontend: browser) |
| Formatação | Prettier 3 nos arquivos JS. HTML/CSS ficam de fora: reformatá-los reescreveria os arquivos sem ganho de verificação |
| Tipos | não aplicável: JavaScript sem TypeScript nem JSDoc tipado. Cobertura via ESLint e testes |
| Testes da API | `node --test`: validação, autenticação, CORS, versão |
| Integração | PostgreSQL 16 descartável (service container): migrations idempotentes, persistência, hash de senha, fluxo completo |
| Testes do frontend | `node --test` + jsdom executando o `app.js` real sobre o `index.html` real, com a API simulada |
| Scripts | `bash -n`, `shellcheck`, `scripts/tests/run.sh` (argumentos, nomes, regras das policies IAM, task definition, deploy sem remoções) |
| Build | `npm run build` do frontend; `docker build` da API, com teste do container (`DB_SSL=true`, migration, health, cadastro) |

## Inventário de recursos do ambiente `lab-deploy`

| Recurso | Nome | Qtde | Existência prevista |
| --- | --- | --- | --- |
| VPC, IGW, 3 sub-redes, route table, 2 security groups | `lab-deploy*` | 1 conjunto | sessão |
| RDS PostgreSQL + DB subnet group | `lab-deploy-db` | 1 | sessão |
| Parâmetros SSM SecureString | `/lab-deploy/db-password`, `/lab-deploy/jwt-secret` | 2 | sessão |
| ECR | `lab-deploy-api` | 1 repo, ~5 imagens | sessão |
| CloudWatch Logs (retenção 1 dia) | `/ecs/lab-deploy` | 1 | sessão |
| IAM roles | `lab-deploy-ecs-exec`, `lab-deploy-github-deploy` | 2 | sessão |
| ECS cluster, serviço, task definitions | `lab-deploy`, `lab-deploy-api` | 1 / 1 / N revisões | sessão |
| Task Fargate da API + IPv4 público | — | 1 (2 durante o deploy) | sessão |
| Task Fargate de migration + IPv4 público | — | 1 por deploy, ~2 min | por deploy |
| Bucket S3 do site | `lab-deploy-site-083712834563` | 1 | sessão |
| GitHub: environment `lab-deploy` e variáveis do repositório | — | — | mantidos após destruir (`LAB_STATE=destroyed`) |
| Provedor OIDC do GitHub | `token.actions.githubusercontent.com` | 1 | preexistente, preservado |

Tags: `Environment=lab-deploy`, `Owner=tamiriscrepalde`, `Project=registro-app`.

## Estimativa de custo

Fonte: AWS Price List (arquivos oficiais `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<serviço>/current/us-east-1/index.json`),
consultados em 24/09/2026 (publicações de 11 a 22/09/2026). Subtotais calculados por script.
Cenário: 3 h de existência (2 h de uso + 1 h de margem para provisionar, repetir e remover), 5 deploys,
cada deploy com ~5 min extras de task (migration ~2 min + sobreposição ~3 min).
Não considera Free Tier nem créditos.

| Recurso | Configuração | Tarifa | Unidade | Subtotal (3 h) |
| --- | --- | --- | --- | --- |
| Fargate API | 0,25 vCPU + 0,5 GB | US$ 0,04048 vCPU-h; US$ 0,004445 GB-h | hora | US$ 0,0370 |
| Fargate extra | migrations + sobreposição (25 min) | idem | hora | US$ 0,0051 |
| IPv4 público da task | 1 endereço | US$ 0,005 | hora | US$ 0,0150 |
| IPv4 extra | migrations + sobreposição | US$ 0,005 | hora | US$ 0,0021 |
| RDS db.t4g.micro Single-AZ PostgreSQL | 1 instância | US$ 0,016 | hora | US$ 0,0480 |
| RDS armazenamento gp3 | 20 GiB | US$ 0,115 | GB-mês | US$ 0,0095 |
| RDS backup | retenção 0, sem snapshot | US$ 0,095 | GB-mês | US$ 0,0000 |
| ECR | ~0,5 GB | US$ 0,10 | GB-mês | US$ 0,0002 |
| S3 site | ~100 PUT, ~5 mil GET, KBs armazenados | US$ 0,005/mil PUT; US$ 0,004/10 mil GET | requisição | US$ 0,0025 |
| Transferência para a internet | ~0,1 GB | US$ 0,09 | GB | US$ 0,0090 |
| CloudWatch Logs | ~0,05 GB ingeridos | US$ 0,50 | GB ingerido | US$ 0,0250 |
| SSM standard + KMS `aws/ssm` | ~1 mil requisições KMS | parâmetro standard sem custo; US$ 0,03/10 mil | requisição | US$ 0,0030 |
| VPC, sub-redes, IGW, SG, ECS, IAM, OIDC | — | sem custo | — | US$ 0,0000 |
| **Total por ambiente e sessão** | | | | **≈ US$ 0,16** |

- **Turma**: US$ 0,16 × número de ambientes (ex.: 10 ambientes ≈ US$ 1,56).
- **Ligado por 24 h**: custo fixo de US$ 0,0365/h → **≈ US$ 0,88**. A meta de US$ 0,50 é ultrapassada
  depois de ~13,7 h ligado. Um alerta de orçamento não desliga nada.
- **Variáveis e incertezas**: créditos de CPU do t4g acima do baseline (US$ 0,075 por vCPU-h, improvável
  com este uso), deploys extras, volume de logs e o tempo real de criação/remoção do RDS (~5 a 15 min cada).
- **Fora da AWS**: GitHub Actions em repositório público sem custo nos runners padrão; o custo do agente
  de IA não está incluído.
