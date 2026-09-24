#!/usr/bin/env bash
# Cria ou atualiza o ambiente do laboratório na AWS e publica uma versão da aplicação.
#
# Provisionamento (acionamento explícito, local, com a credencial da pessoa):
#   scripts/deploy.sh --env lab-deploy --region us-east-1 --account 123456789012 \
#     --provision --github-repo owner/repo [--profile perfil]
#
# Publicação de uma imagem já enviada ao ECR (o CI usa este modo; também serve para recuperar):
#   scripts/deploy.sh --env lab-deploy --region us-east-1 --account 123456789012 \
#     --image-tag <sha-do-commit> [--frontend-dir frontend/dist] [--profile perfil]
#
# Opções:
#   --provision        cria o que faltar (consulta antes de criar) e configura o GitHub; pode repetir
#   --github-repo      owner/repo que recebe a trust OIDC, o environment e as variáveis (com --provision)
#   --image-tag        tag da imagem no ECR (commit); a task usa o digest correspondente
#   --frontend-dir     build validado do frontend (padrão: frontend/dist)
#   --profile          perfil local da AWS CLI; no CI a credencial vem do OIDC
#   --allow-root       aceita a credencial root (desaconselhado)
#
# A publicação não cria rede, banco nem IAM: se algo faltar, falha e pede --provision.
# Este script nunca remove recursos. A remoção é feita somente por scripts/destroy.sh.
set -Eeuo pipefail
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

ENV_ARG='' REGION_ARG='' ACCOUNT_ARG='' PROFILE='' GITHUB_REPO='' IMAGE_TAG=''
PROVISION=false ALLOW_ROOT=false FRONTEND_DIR=frontend/dist
while (($#)); do
  case $1 in
    --env) opt_value "$@" && ENV_ARG=$2 && shift 2 ;;
    --region) opt_value "$@" && REGION_ARG=$2 && shift 2 ;;
    --account) opt_value "$@" && ACCOUNT_ARG=$2 && shift 2 ;;
    --profile) opt_value "$@" && PROFILE=$2 && shift 2 ;;
    --github-repo) opt_value "$@" && GITHUB_REPO=$2 && shift 2 ;;
    --image-tag) opt_value "$@" && IMAGE_TAG=$2 && shift 2 ;;
    --frontend-dir) opt_value "$@" && FRONTEND_DIR=$2 && shift 2 ;;
    --provision) PROVISION=true && shift ;;
    --allow-root) ALLOW_ROOT=true && shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && die "argumento desconhecido: $1" ;;
  esac
done

[[ -n $ENV_ARG && -n $REGION_ARG && -n $ACCOUNT_ARG ]] || {
  usage >&2
  die "--env, --region e --account são obrigatórios"
}
validate_env_name "$ENV_ARG"
validate_region "$REGION_ARG"
validate_account "$ACCOUNT_ARG"
[[ $PROVISION == true || -n $IMAGE_TAG ]] || die "informe --provision, --image-tag ou ambos"
if [[ $PROVISION == true ]]; then
  [[ $GITHUB_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--provision exige --github-repo owner/repo"
  require_cmds gh
  [[ $(gh api "repos/$GITHUB_REPO" --jq '.permissions.admin' 2>/dev/null) == true ]] ||
    die "o gh precisa estar autenticado com permissão de admin em $GITHUB_REPO"
fi
if [[ -n $IMAGE_TAG ]]; then
  [[ $IMAGE_TAG =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || die "--image-tag inválida"
  [[ -f $FRONTEND_DIR/index.html ]] || die "build do frontend não encontrado em $FRONTEND_DIR (rode npm run build em frontend/)"
fi
require_cmds aws jq curl openssl

[[ -n $PROFILE ]] && export AWS_PROFILE=$PROFILE
export AWS_REGION=$REGION_ARG AWS_DEFAULT_REGION=$REGION_ARG AWS_PAGER="" AWS_DEFAULT_OUTPUT=json
set_names "$ENV_ARG" "$REGION_ARG" "$ACCOUNT_ARG"

STEP="validação inicial"
TMP=$(mktemp -d)
summary() { if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; fi; }
on_exit() {
  local rc=$?
  rm -rf "$TMP"
  if ((rc != 0)); then
    printf '\nFALHA na etapa "%s" (código %s). Nenhum recurso foi removido; veja docs/operacao.md.\n' "$STEP" "$rc" >&2
    summary "### ❌ Deploy falhou" "" "| Item | Valor |" "| --- | --- |" "| Ambiente | \`$ENV_NAME\` |" \
      "| Commit | \`${IMAGE_TAG:-n/a}\` |" "| Etapa | $STEP |" "" "Veja o log deste job e docs/operacao.md."
  fi
}
trap on_exit EXIT
step() {
  STEP=$1
  log "$1"
}

check_identity "$ALLOW_ROOT"

# ---------------------------------------------------------------- provisionamento

ensure_vpc() {
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV_NAME" "Name=tag:Environment,Values=$ENV_NAME" \
    --query 'Vpcs[0].VpcId' --output text)
  if [[ $VPC_ID == None ]]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block 10.42.0.0/16 --tag-specifications "$(ec2_tags vpc "$ENV_NAME")" \
      --query Vpc.VpcId --output text)
    aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    info "VPC criada: $VPC_ID"
  else
    info "VPC existente: $VPC_ID"
  fi
}

ensure_igw() {
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=tag:Environment,Values=$ENV_NAME" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [[ $IGW_ID == None ]]; then
    IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "$(ec2_tags internet-gateway "$ENV_NAME")" \
      --query InternetGateway.InternetGatewayId --output text)
    info "internet gateway criado: $IGW_ID"
  fi
  local attached
  attached=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
    --query "InternetGateways[0].Attachments[?VpcId=='$VPC_ID'] | length(@)" --output text)
  ((attached > 0)) || aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
}

# Duas zonas: o DB subnet group exige sub-redes em pelo menos duas AZs, mesmo com RDS Single-AZ.
# use1-az3 fica de fora porque não oferece Fargate.
pick_azs() {
  mapfile -t AZS < <(aws ec2 describe-availability-zones \
    --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
    --query "AvailabilityZones[?ZoneId!='use1-az3'].ZoneName" --output text | tr '\t' '\n' | sort | head -2)
  ((${#AZS[@]} == 2)) || die "a região precisa de duas zonas de disponibilidade"
}

ensure_subnet() { # nome cidr az -> id
  local id
  id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$1" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ $id == None ]]; then
    id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$3" \
      --tag-specifications "$(ec2_tags subnet "$1")" --query Subnet.SubnetId --output text)
    info "sub-rede $1 criada: $id ($3)"
  fi
  printf '%s' "$id"
}

# Só a sub-rede pública tem rota para a internet. As privadas ficam na tabela principal da VPC (só rota local).
ensure_public_routes() {
  local rtb has_default assoc
  rtb=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$ENV_NAME-public" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [[ $rtb == None ]]; then
    rtb=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(ec2_tags route-table "$ENV_NAME-public")" \
      --query RouteTable.RouteTableId --output text)
  fi
  has_default=$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | length(@)" --output text)
  ((has_default > 0)) || aws ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" >/dev/null
  assoc=$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query "RouteTables[0].Associations[?SubnetId=='$PUBLIC_SUBNET'] | length(@)" --output text)
  ((assoc > 0)) || aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$PUBLIC_SUBNET" >/dev/null
}

ensure_sg() { # nome descrição -> id
  local id
  id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [[ $id == None ]]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --tag-specifications "$(ec2_tags security-group "$1")" --query GroupId --output text)
    info "security group $1 criado: $id"
  fi
  printf '%s' "$id"
}

allow_ingress() { # sg-id argumentos-da-regra...
  local sg=$1 out
  shift
  out=$(aws ec2 authorize-security-group-ingress --group-id "$sg" "$@" 2>&1) && return 0
  grep -q 'InvalidPermission.Duplicate' <<<"$out" || die "falha ao liberar entrada em $sg"$'\n'"$out"
}

ensure_secret_param() { # nome bytes-aleatórios
  if probe 'ParameterNotFound' aws ssm get-parameter --name "$1" --query Parameter.Name --output text; then
    info "parâmetro $1 existente"
    return
  fi
  # O valor vai por arquivo temporário (via stdin do jq), nunca pela linha de comando.
  openssl rand -hex "$2" | tr -d '\n' | jq -R --arg n "$1" --argjson t "$(tags_kv)" \
    '{Name:$n, Type:"SecureString", Value:., Tags:$t}' >"$TMP/param.json"
  aws ssm put-parameter --cli-input-json "file://$TMP/param.json" >/dev/null
  rm -f "$TMP/param.json"
  info "parâmetro $1 criado"
}

ensure_db_subnet_group() {
  if probe 'DBSubnetGroupNotFoundFault' aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP"; then
    return
  fi
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Sub-redes privadas do $ENV_NAME" --subnet-ids "$PRIVATE_A" "$PRIVATE_B" \
    --tags "$(tags_kv)" >/dev/null
}

ensure_database() {
  if probe 'DBInstanceNotFound' aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text; then
    info "banco existente (status: $PROBE_OUT)"
  else
    local version orderable base
    version=$(aws rds describe-db-engine-versions --engine postgres --engine-version 16 --default-only \
      --query 'DBEngineVersions[0].EngineVersion' --output text)
    [[ $version == 16.* ]] || die "PostgreSQL 16 indisponível em $REGION"
    orderable=$(aws rds describe-orderable-db-instance-options --engine postgres --engine-version "$version" \
      --db-instance-class db.t4g.micro --query 'length(OrderableDBInstanceOptions)' --output text)
    ((orderable > 0)) || die "db.t4g.micro indisponível para PostgreSQL $version em $REGION"
    base=$(jq -n --arg id "$DB_ID" --arg v "$version" --arg user "$DB_USER" --arg db "$DB_NAME" --arg sg "$SG_DB_ID" \
      --arg sn "$DB_SUBNET_GROUP" --argjson t "$(tags_kv)" '{
      DBInstanceIdentifier: $id, DBInstanceClass: "db.t4g.micro", Engine: "postgres", EngineVersion: $v,
      AllocatedStorage: 20, StorageType: "gp3", MasterUsername: $user, DBName: $db,
      VpcSecurityGroupIds: [$sg], DBSubnetGroupName: $sn, PubliclyAccessible: false, MultiAZ: false,
      BackupRetentionPeriod: 0, StorageEncrypted: true, DeletionProtection: false, CopyTagsToSnapshot: true, Tags: $t}')
    aws ssm get-parameter --name "$PARAM_DB_PASSWORD" --with-decryption --query Parameter.Value --output text |
      tr -d '\n' | jq -R --argjson base "$base" '$base + {MasterUserPassword: .}' >"$TMP/rds.json"
    aws rds create-db-instance --cli-input-json "file://$TMP/rds.json" >/dev/null
    rm -f "$TMP/rds.json"
    info "banco $DB_ID criado (PostgreSQL $version); a criação leva alguns minutos"
  fi
  aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
  info "banco disponível"
}

ensure_ecr() {
  if ! probe 'RepositoryNotFoundException' aws ecr describe-repositories --repository-names "$ECR_REPO"; then
    aws ecr create-repository --repository-name "$ECR_REPO" --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true --tags "$(tags_kv)" >/dev/null
    info "repositório ECR $ECR_REPO criado"
  fi
  aws ecr put-lifecycle-policy --repository-name "$ECR_REPO" --lifecycle-policy-text "$(policy_ecr_lifecycle)" >/dev/null
}

ensure_log_group() {
  local n
  n=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)" --output text)
  ((n > 0)) || aws logs create-log-group --log-group-name "$LOG_GROUP" --tags "$(tags_map)"
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 1
}

ensure_role() { # nome trust-policy
  if probe 'NoSuchEntity' aws iam get-role --role-name "$1"; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "$2"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "$2" --tags "$(tags_kv)" >/dev/null
    info "role $1 criada"
  fi
}

# O provedor OIDC é compartilhado pela conta: reutiliza se existir e o destroy.sh nunca o remove.
ensure_oidc_provider() {
  local arn="arn:aws:iam::$ACCOUNT:oidc-provider/$OIDC_HOST"
  if probe 'NoSuchEntity' aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn"; then
    jq -e '.ClientIDList | index("sts.amazonaws.com")' <<<"$PROBE_OUT" >/dev/null ||
      die "o provedor OIDC existente não aceita a audience sts.amazonaws.com"
    info "provedor OIDC já existe na conta; será reutilizado e preservado"
  else
    aws iam create-open-id-connect-provider --url "https://$OIDC_HOST" --client-id-list sts.amazonaws.com \
      --tags "$(tags_kv)" >/dev/null
    warn "provedor OIDC criado; ele é compartilhado pela conta e não é removido pelo destroy.sh"
  fi
}

# Subject real do token do GitHub para jobs no environment deste laboratório.
oidc_subject() {
  local cfg prefix
  cfg=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub") || die "não foi possível ler o formato do OIDC"
  [[ $(jq -r '.use_default' <<<"$cfg") == true ]] || die "subject OIDC customizado não suportado por este script"
  prefix=$(jq -r --arg r "$GITHUB_REPO" '.sub_claim_prefix // "repo:\($r)"' <<<"$cfg")
  printf '%s:environment:%s' "$prefix" "$ENV_NAME"
}

ensure_iam() {
  ensure_role "$EXEC_ROLE" "$(policy_ecs_exec_trust)"
  aws iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name read-secrets --policy-document "$(policy_ecs_exec_secrets)"

  ensure_oidc_provider
  local sub
  sub=$(oidc_subject)
  info "trust OIDC restrita a: $sub"
  ensure_role "$GITHUB_ROLE" "$(policy_github_trust "$sub")"
  aws iam put-role-policy --role-name "$GITHUB_ROLE" --policy-name deploy --policy-document "$(policy_github_deploy)"
}

ensure_cluster() {
  local status
  status=$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
  [[ $status == ACTIVE ]] && return
  aws ecs create-cluster --cluster-name "$CLUSTER" --settings name=containerInsights,value=disabled \
    --tags "$(tags_ecs)" >/dev/null
  info "cluster $CLUSTER criado"
}

ensure_site_bucket() {
  if ! probe '404|Not Found' aws s3api head-bucket --bucket "$BUCKET"; then
    if [[ $REGION == us-east-1 ]]; then
      aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    info "bucket $BUCKET criado"
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "$(jq -cn --argjson t "$(tags_kv)" '{TagSet:$t}')"
  # ACLs continuam bloqueadas; só a bucket policy de leitura pública é permitida.
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
  aws s3api put-bucket-website --bucket "$BUCKET" \
    --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
  retry 5 aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(policy_site_bucket)" ||
    die "não foi possível aplicar a policy pública; confira o bloqueio de acesso público da conta"
}

configure_github() {
  gh api -X PUT "repos/$GITHUB_REPO/environments/$ENV_NAME" --input - >/dev/null \
    <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  local policies
  policies=$(gh api "repos/$GITHUB_REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '.branch_policies[].name')
  grep -qx main <<<"$policies" || gh api -X POST "repos/$GITHUB_REPO/environments/$ENV_NAME/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null
  gh variable set LAB_ENV --repo "$GITHUB_REPO" --body "$ENV_NAME"
  gh variable set AWS_REGION --repo "$GITHUB_REPO" --body "$REGION"
  gh variable set AWS_ACCOUNT_ID --repo "$GITHUB_REPO" --body "$ACCOUNT"
  gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPO" --body "arn:aws:iam::$ACCOUNT:role/$GITHUB_ROLE"
  gh variable set LAB_STATE --repo "$GITHUB_REPO" --body active
  info "environment $ENV_NAME (somente main) e variáveis configurados em $GITHUB_REPO"
}

provision() {
  OWNER=${GITHUB_REPO%%/*}
  step "Provisionamento: rede"
  ensure_vpc
  ensure_igw
  pick_azs
  PUBLIC_SUBNET=$(ensure_subnet "$ENV_NAME-public-a" 10.42.0.0/24 "${AZS[0]}")
  PRIVATE_A=$(ensure_subnet "$ENV_NAME-private-a" 10.42.10.0/24 "${AZS[0]}")
  PRIVATE_B=$(ensure_subnet "$ENV_NAME-private-b" 10.42.11.0/24 "${AZS[1]}")
  ensure_public_routes

  step "Provisionamento: security groups"
  SG_API_ID=$(ensure_sg "$SG_API" "API $ENV_NAME: porta $API_PORT publica")
  SG_DB_ID=$(ensure_sg "$SG_DB" "RDS $ENV_NAME: somente tasks da API")
  allow_ingress "$SG_API_ID" --protocol tcp --port "$API_PORT" --cidr 0.0.0.0/0
  allow_ingress "$SG_DB_ID" --protocol tcp --port 5432 --source-group "$SG_API_ID"

  step "Provisionamento: segredos"
  if ! probe 'ParameterNotFound' aws ssm get-parameter --name "$PARAM_DB_PASSWORD" --query Parameter.Name &&
    probe 'DBInstanceNotFound' aws rds describe-db-instances --db-instance-identifier "$DB_ID"; then
    die "o banco $DB_ID existe mas $PARAM_DB_PASSWORD não; a senha do banco não pode ser recuperada"
  fi
  ensure_secret_param "$PARAM_DB_PASSWORD" 24
  ensure_secret_param "$PARAM_JWT_SECRET" 32

  step "Provisionamento: banco (RDS PostgreSQL)"
  ensure_db_subnet_group
  ensure_database

  step "Provisionamento: ECR, logs, IAM e ECS"
  ensure_ecr
  ensure_log_group
  ensure_iam
  ensure_cluster

  step "Provisionamento: site (S3 Static Website)"
  ensure_site_bucket

  step "Provisionamento: GitHub"
  configure_github
  log "Ambiente $ENV_NAME provisionado"
}

# ---------------------------------------------------------------- publicação

discover() {
  local missing=() out
  out=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV_NAME" "Name=tag:Environment,Values=$ENV_NAME" \
    --query "Vpcs[0].[VpcId, Tags[?Key=='Owner']|[0].Value]" --output text)
  read -r VPC_ID OWNER <<<"$out"
  if [[ $VPC_ID == None ]]; then
    missing+=(vpc)
  else
    PUBLIC_SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$ENV_NAME-public-a" \
      --query 'Subnets[0].SubnetId' --output text)
    SG_API_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_API" \
      --query 'SecurityGroups[0].GroupId' --output text)
    [[ $PUBLIC_SUBNET != None ]] || missing+=(sub-rede-publica)
    [[ $SG_API_ID != None ]] || missing+=(security-group-api)
  fi
  if probe 'DBInstanceNotFound' aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].[DBInstanceStatus, Endpoint.Address]' --output text; then
    local db_status
    read -r db_status DB_HOST <<<"$PROBE_OUT"
    [[ $db_status == available ]] || missing+=("banco-disponível(status=$db_status)")
  else
    missing+=(banco)
  fi
  [[ $(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text) == ACTIVE ]] ||
    missing+=(cluster)
  probe 'RepositoryNotFoundException' aws ecr describe-repositories --repository-names "$ECR_REPO" || missing+=(ecr)
  probe '404|Not Found' aws s3api head-bucket --bucket "$BUCKET" || missing+=(bucket)
  [[ $(aws ssm describe-parameters --parameter-filters "Key=Name,Values=$PARAM_DB_PASSWORD,$PARAM_JWT_SECRET" \
    --query 'length(Parameters)' --output text) == 2 ]] || missing+=(segredos)
  [[ $(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)" --output text) == 1 ]] || missing+=(log-group)
  ((${#missing[@]} == 0)) || die "ambiente $ENV_NAME incompleto (faltando: ${missing[*]}). Provisione antes com --provision."
  info "VPC $VPC_ID, sub-rede $PUBLIC_SUBNET, banco $DB_HOST"
}

resolve_image() {
  local digest
  probe 'ImageNotFoundException' aws ecr describe-images --repository-name "$ECR_REPO" \
    --image-ids "imageTag=$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text ||
    die "a imagem $ECR_REPO:$IMAGE_TAG não está no ECR"
  digest=$PROBE_OUT
  IMAGE_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO@$digest
  info "imagem: $IMAGE_URI"
}

network_config() {
  jq -cn --arg s "$PUBLIC_SUBNET" --arg g "$SG_API_ID" \
    '{awsvpcConfiguration: {subnets: [$s], securityGroups: [$g], assignPublicIp: "ENABLED"}}'
}

task_logs() { # task-arn
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "api/$CONTAINER/${1##*/}" \
    --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | tail -20 | sed 's/^/    | /' >&2 || true
}

# Migration em task única, antes de trocar a versão da API. Falha interrompe o deploy.
run_migration() {
  local run task_arn result code
  run=$(aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE --task-definition "$TASK_DEF_ARN" \
    --network-configuration "$(network_config)" --started-by deploy-migrate --propagate-tags TASK_DEFINITION \
    --overrides "$(jq -cn --arg n "$CONTAINER" '{containerOverrides: [{name: $n, command: ["node", "src/migrate.js"]}]}')")
  task_arn=$(jq -r '.tasks[0].taskArn // empty' <<<"$run")
  [[ -n $task_arn ]] || die "a task de migration não iniciou: $(jq -c '.failures' <<<"$run")"
  info "task de migration: ${task_arn##*/}"
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
  result=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
    --query 'tasks[0].{code: containers[0].exitCode, reason: stoppedReason, container: containers[0].reason}')
  code=$(jq -r '.code // "sem-código"' <<<"$result")
  task_logs "$task_arn"
  [[ $code == 0 ]] || die "migration falhou (exit=$code; $(jq -r '[.reason, .container] | map(select(.)) | join("; ")' <<<"$result"))"
  info "migration concluída (exit=0)"
}

deploy_service() {
  local cfg='{"deploymentCircuitBreaker":{"enable":true,"rollback":true},"maximumPercent":200,"minimumHealthyPercent":100}'
  if [[ $(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].status' --output text) == ACTIVE ]]; then
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --deployment-configuration "$cfg" >/dev/null
  else
    aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 --launch-type FARGATE --network-configuration "$(network_config)" \
      --deployment-configuration "$cfg" --propagate-tags SERVICE --tags "$(tags_ecs)" >/dev/null
    info "serviço $SERVICE criado"
  fi
}

show_stopped_tasks() {
  local arns
  mapfile -t arns < <(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status STOPPED \
    --query 'taskArns[:5]' --output text | tr '\t' '\n' | grep . || true)
  ((${#arns[@]})) || return 0
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "${arns[@]}" |
    jq -r '.tasks[] | "    task \(.taskArn | split("/") | last): \(.stoppedReason // "-") / \(.containers[0].reason // "-")"' >&2
  task_logs "${arns[0]}"
}

# O waiter services-stable pode retornar antes do fim do rollout: espera o rolloutState do deployment
# primário e confirma que ele é a revisão nova (e não um rollback do circuit breaker).
wait_rollout() {
  local deadline=$((SECONDS + 1200)) svc primary state reason
  while :; do
    svc=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0]')
    primary=$(jq -r '.deployments[] | select(.status == "PRIMARY") | .taskDefinition' <<<"$svc")
    state=$(jq -r '.deployments[] | select(.status == "PRIMARY") | .rolloutState' <<<"$svc")
    reason=$(jq -r '.deployments[] | select(.status == "PRIMARY") | .rolloutStateReason // ""' <<<"$svc")
    if [[ $primary != "$TASK_DEF_ARN" ]]; then
      show_stopped_tasks
      die "o circuit breaker reverteu o serviço para ${primary##*/}"
    fi
    case $state in
      COMPLETED) break ;;
      FAILED)
        show_stopped_tasks
        die "rollout falhou: $reason"
        ;;
    esac
    ((SECONDS < deadline)) || die "tempo esgotado aguardando o rollout (estado: $state)"
    info "rollout $state: $(jq -r '"\(.runningCount) em execução, \(.pendingCount) pendente(s)"' <<<"$svc")"
    sleep 15
  done
  info "rollout concluído com ${TASK_DEF_ARN##*/}"
}

# O IP público muda a cada task nova; só é lido depois que a revisão nova está saudável.
discover_api_ip() {
  local arns eni
  mapfile -t arns < <(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING \
    --query 'taskArns' --output text | tr '\t' '\n' | grep .)
  ((${#arns[@]})) || die "nenhuma task em execução no serviço"
  eni=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "${arns[@]}" | jq -r --arg td "$TASK_DEF_ARN" '
    [.tasks[] | select(.taskDefinitionArn == $td and .lastStatus == "RUNNING")] | sort_by(.startedAt) | last
    | .attachments[] | select(.type == "ElasticNetworkInterface") | .details[] | select(.name == "networkInterfaceId") | .value')
  [[ $eni == eni-* ]] || die "não foi possível identificar a interface de rede da task nova"
  API_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
  [[ $API_IP =~ ^[0-9.]+$ ]] || die "a task nova não tem IPv4 público"
  API_URL=http://$API_IP:$API_PORT
  info "API em $API_URL"
}

publish_frontend() {
  mkdir -p "$TMP/site"
  cp -R "$FRONTEND_DIR/." "$TMP/site/"
  printf 'window.APP_CONFIG = %s;\n' "$(jq -cn --arg api "$API_URL" --arg v "${IMAGE_TAG:0:7}" '{apiUrl: $api, version: $v}')" \
    >"$TMP/site/config.js"
  # Sem CDN na frente: no-cache faz o navegador revalidar e exibir a versão nova sem invalidação.
  aws s3 sync "$TMP/site" "s3://$BUCKET/" --delete --cache-control no-cache --only-show-errors
  info "site publicado em $SITE_URL"
}

CHECKS=()
check_ok() {
  CHECKS+=("✅ $1")
  info "ok: $1"
}

verify() {
  local health headers email password token body code
  health=$(curl -fsS --max-time 10 --retry 10 --retry-delay 3 --retry-all-errors "$API_URL/api/health") ||
    die "a API não respondeu em $API_URL/api/health"
  [[ $(jq -r .version <<<"$health") == "$IMAGE_TAG" ]] || die "a API respondeu outra versão: $health"
  check_ok "health da API responde com a versão $IMAGE_TAG"

  headers=$(curl -fsS -o /dev/null -D - -X OPTIONS -H "Origin: $SITE_URL" -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' "$API_URL/api/register")
  grep -qi "^access-control-allow-origin: $SITE_URL" <<<"$headers" || die "CORS não libera a origem $SITE_URL"
  check_ok "CORS libera somente a origem do site"

  body=$(curl -fsS --max-time 10 "$SITE_URL/") || die "o site não respondeu em $SITE_URL"
  grep -q 'config.js' <<<"$body" || die "o site não serviu o index.html esperado"
  body=$(curl -fsS --max-time 10 -D "$TMP/cfg.h" "$SITE_URL/config.js")
  grep -qF "\"apiUrl\":\"$API_URL\"" <<<"$body" || die "config.js publicado não aponta para $API_URL"
  grep -qi '^cache-control: no-cache' "$TMP/cfg.h" || die "config.js sem Cache-Control: no-cache"
  check_ok "site servido pelo S3 com config.js apontando para a API nova"

  # Registro sentinela: 201 no primeiro deploy, 409 nos seguintes (prova que os dados persistiram).
  password=$(openssl rand -hex 12)
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' \
    -d "{\"name\":\"Sentinela\",\"email\":\"sentinela@example.com\",\"password\":\"$password\"}" "$API_URL/api/register")
  case $code in
    201) check_ok "registro sentinela criado (primeira publicação neste banco)" ;;
    409) check_ok "registro sentinela de publicações anteriores preservado" ;;
    *) die "cadastro do registro sentinela retornou HTTP $code" ;;
  esac

  email="smoke-${IMAGE_TAG:0:7}-$(date +%s)@example.com"
  body=$(curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "{\"name\":\"Smoke\",\"email\":\"$email\",\"password\":\"$password\"}" "$API_URL/api/register") ||
    die "cadastro de teste falhou"
  token=$(jq -r '.token' <<<"$body")
  body=$(curl -fsS --max-time 10 -H "Authorization: Bearer $token" "$API_URL/api/me") || die "/api/me falhou"
  [[ $(jq -r '.user.email' <<<"$body") == "$email" ]] || die "/api/me devolveu outro usuário"
  curl -fsS -o /dev/null --max-time 10 -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$API_URL/api/login" || die "login de teste falhou"
  check_ok "cadastro, login e consulta ao banco funcionando"
}

publish() {
  step "Publicação: conferindo o ambiente"
  discover
  resolve_image
  step "Publicação: task definition"
  TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$(task_definition_json)" \
    --query taskDefinition.taskDefinitionArn --output text)
  info "task definition: ${TASK_DEF_ARN##*/}"
  step "Publicação: migrations"
  run_migration
  step "Publicação: serviço ECS"
  deploy_service
  wait_rollout
  discover_api_ip
  step "Publicação: frontend"
  publish_frontend
  step "Verificação funcional"
  verify

  STEP=concluído
  log "Aplicação publicada"
  printf '    Site:    %s\n    API:     %s\n    Commit:  %s\n    Imagem:  %s\n' "$SITE_URL" "$API_URL" "$IMAGE_TAG" "$IMAGE_URI"
  printf '    %s\n' "${CHECKS[@]}"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "site_url=$SITE_URL" >>"$GITHUB_OUTPUT"; fi
  summary "### ✅ Deploy concluído" "" "| Item | Valor |" "| --- | --- |" "| Ambiente | \`$ENV_NAME\` |" \
    "| Commit | \`$IMAGE_TAG\` |" "| Site | $SITE_URL |" "| API | $API_URL |" "| Imagem | \`$IMAGE_URI\` |" \
    "| Task definition | \`${TASK_DEF_ARN##*/}\` |" "" "${CHECKS[@]/#/- }" "" \
    "Tráfego em HTTP, sem criptografia: use apenas dados sintéticos."
}

if [[ $PROVISION == true ]]; then provision; fi
if [[ -n $IMAGE_TAG ]]; then
  publish
else
  STEP=concluído
  log "Próximo passo: publicar uma versão pelo pipeline (push na main ou gh workflow run pipeline.yml)"
fi
