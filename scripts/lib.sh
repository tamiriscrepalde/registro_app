#!/usr/bin/env bash
# Funções compartilhadas por deploy.sh, destroy.sh e scripts/tests/run.sh.
# Só define funções e nomes; carregar este arquivo não chama a AWS.
# shellcheck disable=SC2034 # os nomes definidos aqui são usados pelos scripts que carregam o arquivo

PROJECT=registro-app
OIDC_HOST=token.actions.githubusercontent.com

log() { printf '\n==> %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "dependências ausentes: ${missing[*]}"
}

# Garante que a opção recebeu um valor: opt_value --env "$2"
opt_value() { [[ -n ${2:-} && ${2:-} != --* ]] || die "$1 precisa de um valor"; }

validate_env_name() {
  [[ $1 =~ ^[a-z][a-z0-9-]{2,20}[a-z0-9]$ ]] || die "ambiente inválido '$1': 4 a 23 caracteres [a-z0-9-], começando por letra"
}
validate_region() { [[ $1 =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "região inválida '$1'"; }
validate_account() { [[ $1 =~ ^[0-9]{12}$ ]] || die "conta AWS inválida '$1': use os 12 dígitos"; }

# Endpoint do S3 Static Website: as regiões mais antigas usam hífen antes da região, as demais usam ponto.
site_url() {
  local sep=.
  case $2 in
    us-east-1 | us-west-1 | us-west-2 | eu-west-1 | ap-southeast-1 | ap-southeast-2 | ap-northeast-1 | sa-east-1) sep=- ;;
  esac
  printf 'http://%s.s3-website%s%s.amazonaws.com' "$1" "$sep" "$2"
}

# Nomes derivados do ambiente. deploy.sh e destroy.sh usam exatamente os mesmos.
set_names() {
  ENV_NAME=$1 REGION=$2 ACCOUNT=$3
  CLUSTER=$ENV_NAME
  SERVICE=$ENV_NAME-api
  TASK_FAMILY=$ENV_NAME-api
  CONTAINER=api
  ECR_REPO=$ENV_NAME-api
  DB_ID=$ENV_NAME-db
  DB_SUBNET_GROUP=$ENV_NAME-db
  DB_NAME=registro
  DB_USER=app
  LOG_GROUP=/ecs/$ENV_NAME
  EXEC_ROLE=$ENV_NAME-ecs-exec
  GITHUB_ROLE=$ENV_NAME-github-deploy
  BUCKET=$ENV_NAME-site-$ACCOUNT
  PARAM_DB_PASSWORD=/$ENV_NAME/db-password
  PARAM_JWT_SECRET=/$ENV_NAME/jwt-secret
  SG_API=$ENV_NAME-api
  SG_DB=$ENV_NAME-db
  API_PORT=3000
  SITE_URL=$(site_url "$BUCKET" "$REGION")
}

param_arn() { printf 'arn:aws:ssm:%s:%s:parameter%s' "$REGION" "$ACCOUNT" "$1"; }

# Tags nos formatos que cada serviço aceita. OWNER vem do chamador.
tags_kv() {
  jq -cn --arg e "$ENV_NAME" --arg o "${OWNER:-desconhecido}" --arg p "$PROJECT" \
    '[{Key:"Environment",Value:$e},{Key:"Owner",Value:$o},{Key:"Project",Value:$p}]'
}
tags_ecs() { tags_kv | jq -c 'map({key:.Key, value:.Value})'; }
tags_map() { tags_kv | jq -c 'map({(.Key):.Value}) | add'; }
ec2_tags() { # tipo-de-recurso nome
  jq -cn --arg t "$1" --arg n "$2" --argjson tags "$(tags_kv)" '[{ResourceType:$t, Tags:($tags + [{Key:"Name",Value:$n}])}]'
}

# Confiança da role do CI: só o environment do repositório informado, com audience do STS.
policy_github_trust() { # subject
  jq -n --arg p "arn:aws:iam::$ACCOUNT:oidc-provider/$OIDC_HOST" --arg h "$OIDC_HOST" --arg sub "$1" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {Federated: $p},
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {StringEquals: {("\($h):aud"): "sts.amazonaws.com", ("\($h):sub"): $sub}}
    }]}'
}

# Permissões da role do CI: publicar uma versão em recursos já provisionados.
# Não cria nem remove rede, banco, IAM ou bucket; isso fica com o provisionamento local.
policy_github_deploy() {
  jq -n --arg a "$ACCOUNT" --arg r "$REGION" --arg cluster "$CLUSTER" --arg svc "$SERVICE" \
    --arg fam "$TASK_FAMILY" --arg repo "$ECR_REPO" --arg db "$DB_ID" --arg bucket "$BUCKET" \
    --arg lg "$LOG_GROUP" --arg exec "$EXEC_ROLE" '
  "arn:aws:ecs:\($r):\($a):cluster/\($cluster)" as $clusterArn |
  "arn:aws:ecs:\($r):\($a):task-definition/\($fam):*" as $tdArn |
  "arn:aws:ecs:\($r):\($a):service/\($cluster)/\($svc)" as $svcArn |
  "arn:aws:ecs:\($r):\($a):task/\($cluster)/*" as $taskArn |
  {Version: "2012-10-17", Statement: [
    {Sid: "DiscoveryWithoutResourceLevel", Effect: "Allow", Resource: "*", Action: [
      "ecr:GetAuthorizationToken", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces", "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition",
      "ssm:DescribeParameters", "logs:DescribeLogGroups"]},
    {Sid: "PushImage", Effect: "Allow", Resource: "arn:aws:ecr:\($r):\($a):repository/\($repo)", Action: [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeRepositories"]},
    {Sid: "Cluster", Effect: "Allow", Resource: $clusterArn, Action: ["ecs:DescribeClusters"]},
    {Sid: "RunMigration", Effect: "Allow", Resource: $tdArn, Action: ["ecs:RunTask"],
      Condition: {ArnEquals: {"ecs:cluster": $clusterArn}}},
    {Sid: "Service", Effect: "Allow", Resource: $svcArn,
      Action: ["ecs:CreateService", "ecs:UpdateService", "ecs:DescribeServices"]},
    {Sid: "TasksInCluster", Effect: "Allow", Resource: "*", Action: ["ecs:ListTasks", "ecs:DescribeTasks"],
      Condition: {ArnEquals: {"ecs:cluster": $clusterArn}}},
    {Sid: "TagOnCreate", Effect: "Allow", Resource: [$tdArn, $svcArn, $taskArn], Action: ["ecs:TagResource"],
      Condition: {StringEquals: {"ecs:CreateAction": ["RegisterTaskDefinition", "CreateService", "RunTask"]}}},
    {Sid: "PassExecutionRole", Effect: "Allow", Resource: "arn:aws:iam::\($a):role/\($exec)", Action: ["iam:PassRole"],
      Condition: {StringEquals: {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}},
    {Sid: "Database", Effect: "Allow", Resource: "arn:aws:rds:\($r):\($a):db:\($db)", Action: ["rds:DescribeDBInstances"]},
    {Sid: "SiteBucket", Effect: "Allow", Resource: "arn:aws:s3:::\($bucket)", Action: ["s3:ListBucket"]},
    {Sid: "SiteObjects", Effect: "Allow", Resource: "arn:aws:s3:::\($bucket)/*",
      Action: ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]},
    {Sid: "Logs", Effect: "Allow", Resource: "arn:aws:logs:\($r):\($a):log-group:\($lg):*",
      Action: ["logs:GetLogEvents", "logs:FilterLogEvents"]}
  ]}'
}

policy_ecs_exec_trust() {
  jq -n --arg a "$ACCOUNT" '{Version: "2012-10-17", Statement: [{
    Effect: "Allow", Principal: {Service: "ecs-tasks.amazonaws.com"}, Action: "sts:AssumeRole",
    Condition: {StringEquals: {"aws:SourceAccount": $a}}}]}'
}

# A task só lê os dois segredos do próprio ambiente.
policy_ecs_exec_secrets() {
  jq -n --arg pw "$(param_arn "$PARAM_DB_PASSWORD")" --arg jwt "$(param_arn "$PARAM_JWT_SECRET")" \
    '{Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["ssm:GetParameters"], Resource: [$pw, $jwt]}]}'
}

# Leitura pública apenas dos objetos do site; escrita continua restrita a IAM.
policy_site_bucket() {
  jq -n --arg b "$BUCKET" '{Version: "2012-10-17", Statement: [{
    Sid: "PublicReadSite", Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "arn:aws:s3:::\($b)/*"}]}'
}

policy_ecr_lifecycle() {
  jq -cn '{rules: [{rulePriority: 1, description: "Mantém as 10 imagens mais recentes",
    selection: {tagStatus: "any", countType: "imageCountMoreThan", countNumber: 10}, action: {type: "expire"}}]}'
}

# Task definition da API. Entradas: IMAGE_URI (fixada por digest), DB_HOST, IMAGE_TAG e os nomes do ambiente.
task_definition_json() {
  jq -n --arg family "$TASK_FAMILY" --arg exec "arn:aws:iam::$ACCOUNT:role/$EXEC_ROLE" --arg image "$IMAGE_URI" \
    --arg name "$CONTAINER" --argjson port "$API_PORT" --arg pghost "$DB_HOST" --arg pguser "$DB_USER" \
    --arg pgdb "$DB_NAME" --arg cors "$SITE_URL" --arg version "$IMAGE_TAG" --arg lg "$LOG_GROUP" \
    --arg region "$REGION" --arg pw "$(param_arn "$PARAM_DB_PASSWORD")" --arg jwt "$(param_arn "$PARAM_JWT_SECRET")" \
    --argjson tags "$(tags_ecs)" '{
    family: $family, networkMode: "awsvpc", requiresCompatibilities: ["FARGATE"], cpu: "256", memory: "512",
    runtimePlatform: {cpuArchitecture: "X86_64", operatingSystemFamily: "LINUX"},
    executionRoleArn: $exec,
    containerDefinitions: [{
      name: $name, image: $image, essential: true,
      portMappings: [{containerPort: $port, protocol: "tcp"}],
      environment: [
        {name: "PORT", value: ($port | tostring)}, {name: "DB_SSL", value: "true"},
        {name: "PGHOST", value: $pghost}, {name: "PGPORT", value: "5432"},
        {name: "PGUSER", value: $pguser}, {name: "PGDATABASE", value: $pgdb},
        {name: "CORS_ORIGIN", value: $cors}, {name: "APP_VERSION", value: $version}],
      secrets: [{name: "PGPASSWORD", valueFrom: $pw}, {name: "JWT_SECRET", valueFrom: $jwt}],
      healthCheck: {
        command: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\($port)/api/health > /dev/null || exit 1"],
        interval: 10, timeout: 5, retries: 3, startPeriod: 15},
      linuxParameters: {initProcessEnabled: true},
      logConfiguration: {logDriver: "awslogs",
        options: {"awslogs-group": $lg, "awslogs-region": $region, "awslogs-stream-prefix": "api"}}
    }],
    tags: $tags}'
}

# Consulta um recurso: retorna 0 se existe, 1 se a saída contém o padrão de "não encontrado".
# Qualquer outro erro (permissão, rede) encerra o script com a saída real da AWS CLI.
probe() {
  local pattern=$1 out
  shift
  if out=$("$@" 2>&1); then
    PROBE_OUT=$out
    return 0
  fi
  grep -Eq "$pattern" <<<"$out" && return 1
  die "falha em: $*"$'\n'"$out"
}

retry() { # tentativas comando...
  local n=$1 i
  shift
  for ((i = 1; ; i++)); do
    "$@" && return 0
    ((i >= n)) && return 1
    sleep $((i * 5))
  done
}

# Valida conta e tipo de credencial antes de qualquer alteração.
check_identity() { # allow_root(true|false)
  local id acct arn
  id=$(aws sts get-caller-identity --output json) || die "não foi possível autenticar na AWS"
  acct=$(jq -r .Account <<<"$id")
  arn=$(jq -r .Arn <<<"$id")
  [[ $acct == "$ACCOUNT" ]] || die "a credencial é da conta $acct; esperado $ACCOUNT"
  if [[ $arn == *":root" ]]; then
    [[ $1 == true ]] || die "credencial root recusada; use um usuário/role IAM ou passe --allow-root"
    warn "usando a credencial root por decisão explícita (--allow-root)"
  fi
  info "identidade: $arn"
}
