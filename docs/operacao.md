# Operação do ambiente na AWS

Comandos para o ambiente `lab-deploy` da conta `083712834563` em `us-east-1`. Ajuste `--env`, `--account`,
`--region` e `--profile` para outro ambiente. O tráfego é HTTP sem criptografia: use só dados sintéticos.

## Ciclo de vida

| Etapa | Como |
| --- | --- |
| Provisionar (explícito, local) | `scripts/deploy.sh --env lab-deploy --region us-east-1 --account 083712834563 --provision --github-repo tamiriscrepalde/registro_app --profile <perfil>` |
| Primeira publicação | `gh workflow run pipeline.yml --ref main` (ou um push na `main`) |
| Atualizar | push na `main` (inclusive merge de PR): validações → imagem no ECR → migration → ECS → site → verificação |
| Encerrar | `scripts/destroy.sh --env lab-deploy --region us-east-1 --account 083712834563 --github-repo tamiriscrepalde/registro_app --profile <perfil>` |

O `destroy.sh` pede que você digite o nome do ambiente. `--yes` dispensa a pergunta e só deve ser usado
depois da confirmação explícita da responsável. Ele marca `LAB_STATE=destroyed` antes de remover; a partir
daí o pipeline só informa que o laboratório está encerrado. Um novo `--provision` reativa o ambiente.

## Onde ver o que aconteceu

- **Pipeline**: aba Actions do repositório. O resumo do job `Deploy na AWS` traz commit, URLs, imagem,
  task definition e o resultado de cada verificação; em falha, a etapa que falhou.
- **Logs da API e das migrations** (retenção de 1 dia):

  ```bash
  aws logs tail /ecs/lab-deploy --follow --profile <perfil>            # tudo
  aws logs tail /ecs/lab-deploy --since 30m --filter-pattern Falha      # erros de migration
  ```

- **Estado do serviço e motivo de tasks paradas**:

  ```bash
  aws ecs describe-services --cluster lab-deploy --services lab-deploy-api \
    --query 'services[0].deployments[].{status:status,rollout:rolloutState,td:taskDefinition,motivo:rolloutStateReason}'
  aws ecs list-tasks --cluster lab-deploy --desired-status STOPPED
  aws ecs describe-tasks --cluster lab-deploy --tasks <arn> --query 'tasks[].{motivo:stoppedReason,container:containers[0].reason}'
  ```

## Recuperar uma entrega com falha

1. **Falha em teste, lint, validação ou build**: o job `Deploy na AWS` não roda e a versão anterior continua
   no ar. Corrija e faça um novo push.
2. **Falha na migration**: o deploy para antes de trocar a API; a versão anterior continua no ar.
   Veja os logs acima, corrija a migration e faça um novo push.
3. **Falha no rollout** (task nova não fica saudável): o circuit breaker volta para a revisão anterior e o
   job falha. O site continua apontando para a API anterior, que segue em execução.
4. **Falha na verificação funcional**: a versão nova está no ar mas algo não respondeu como esperado.
   Leia o resumo do job e os logs. Para voltar à versão anterior, reexecute na aba Actions o run do commit
   anterior (**Re-run all jobs**): ele valida de novo e publica a imagem daquele commit, que continua no ECR.
   Localmente, o equivalente é:

   ```bash
   git switch --detach <commit-anterior>
   (cd frontend && npm ci && npm run build)
   scripts/deploy.sh --env lab-deploy --region us-east-1 --account 083712834563 \
     --image-tag "$(git rev-parse HEAD)" --profile <perfil>
   git switch main
   ```

Voltar a versão da aplicação **não desfaz migrations nem restaura dados**. As migrations precisam manter o
schema compatível com a versão anterior (expandir antes, remover depois).

## O site parou de encontrar a API

O IP público da task muda a cada deploy e sempre que o ECS substitui a task (falha, manutenção). Se a task
for substituída fora de um deploy, o `config.js` do site continua apontando para o IP antigo. Para corrigir,
republique a versão atual: `gh workflow run pipeline.yml --ref main`.
