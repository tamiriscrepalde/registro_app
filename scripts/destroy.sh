#!/usr/bin/env bash
# Remove os recursos exclusivos de um ambiente do laboratório, INCLUINDO o banco e os dados de teste.
#
# Uso:
#   scripts/destroy.sh --env lab-deploy --region us-east-1 --account 123456789012 \
#     --github-repo owner/repo [--profile perfil] [--yes] [--allow-root]
#
# Sem --yes, mostra o que será removido e pede que a pessoa digite o nome do ambiente.
# --yes é a opção não interativa, para o agente usar depois de receber a confirmação na conversa.
#
# O banco é removido sem snapshot final e sem backups retidos (dados sintéticos e descartáveis).
# Antes de remover, marca LAB_STATE=destroyed no GitHub para o pipeline não publicar mais.
# Preserva recursos compartilhados da conta, como o provedor OIDC do GitHub.
# Ao final confere por identificador o que restou e retorna erro se algo não foi removido.
# shellcheck disable=SC2317,SC2329 # as funções remove_* são chamadas indiretamente por run_step (0.9 usa SC2317, 0.11 usa SC2329)
set -Eeuo pipefail
shopt -s inherit_errexit

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

ENV_ARG='' REGION_ARG='' ACCOUNT_ARG='' PROFILE='' GITHUB_REPO='' YES=false ALLOW_ROOT=false
while (($#)); do
  case $1 in
    --env) opt_value "$@" && ENV_ARG=$2 && shift 2 ;;
    --region) opt_value "$@" && REGION_ARG=$2 && shift 2 ;;
    --account) opt_value "$@" && ACCOUNT_ARG=$2 && shift 2 ;;
    --profile) opt_value "$@" && PROFILE=$2 && shift 2 ;;
    --github-repo) opt_value "$@" && GITHUB_REPO=$2 && shift 2 ;;
    --yes) YES=true && shift ;;
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
[[ $GITHUB_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--github-repo owner/repo é obrigatório"
require_cmds aws jq gh
[[ $(gh api "repos/$GITHUB_REPO" --jq '.permissions.admin' 2>/dev/null) == true ]] ||
  die "o gh precisa estar autenticado com permissão de admin em $GITHUB_REPO"

[[ -n $PROFILE ]] && export AWS_PROFILE=$PROFILE
export AWS_REGION=$REGION_ARG AWS_DEFAULT_REGION=$REGION_ARG AWS_PAGER="" AWS_DEFAULT_OUTPUT=json
set_names "$ENV_ARG" "$REGION_ARG" "$ACCOUNT_ARG"
check_identity "$ALLOW_ROOT"

cat >&2 <<EOF

Este comando REMOVE o ambiente '$ENV_NAME' da conta $ACCOUNT ($REGION):
  - serviço, tasks e cluster ECS, task definitions e imagens do ECR ($ECR_REPO)
  - banco RDS $DB_ID com TODOS os dados de teste, sem snapshot final e sem backups retidos
  - bucket $BUCKET (site), parâmetros SSM /$ENV_NAME/*, logs $LOG_GROUP
  - roles IAM $EXEC_ROLE e $GITHUB_ROLE, VPC $ENV_NAME e toda a rede dela
Preserva: o provedor OIDC do GitHub, compartilhado pela conta.
EOF
if [[ $YES != true ]]; then
  [[ -t 0 ]] || die "execução não interativa: use --yes somente após a confirmação explícita da pessoa"
  read -r -p "Digite o nome do ambiente ($ENV_NAME) para confirmar: " answer
  [[ $answer == "$ENV_NAME" ]] || die "confirmação não recebida; nada foi removido"
fi

gone() { info "já removido: $1"; }

list_lines() { tr '\t' '\n' | grep . || true; }

remove_ecs() {
  local status svc_status arns=()
  status=$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)
  if [[ $status != ACTIVE ]]; then
    gone "cluster e serviço $CLUSTER"
    return
  fi
  svc_status=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].status' --output text)
  if [[ $svc_status == ACTIVE ]]; then
    aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force >/dev/null
    info "serviço $SERVICE em remoção"
  fi
  mapfile -t arns < <(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns' --output text | list_lines)
  for a in "${arns[@]}"; do aws ecs stop-task --cluster "$CLUSTER" --task "$a" --reason destroy.sh >/dev/null; done
  if [[ $svc_status == ACTIVE || $svc_status == DRAINING ]]; then
    aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE"
  fi
  if ((${#arns[@]})); then aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "${arns[@]}"; fi
  retry 6 aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null
  info "cluster $CLUSTER removido"
}

task_definition_arns() { # ACTIVE|INACTIVE
  aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --status "$1" --query 'taskDefinitionArns' --output text |
    list_lines | grep -E ":task-definition/$TASK_FAMILY:[0-9]+$" || true
}

remove_task_definitions() {
  local arns=() i
  mapfile -t arns < <(task_definition_arns ACTIVE)
  for a in "${arns[@]}"; do aws ecs deregister-task-definition --task-definition "$a" >/dev/null; done
  mapfile -t arns < <(task_definition_arns INACTIVE)
  for ((i = 0; i < ${#arns[@]}; i += 10)); do
    aws ecs delete-task-definitions --task-definitions "${arns[@]:i:10}" >/dev/null
  done
  info "${#arns[@]} revisão(ões) de task definition removida(s)"
}

remove_database() {
  if probe 'DBInstanceNotFound' aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text; then
    if [[ $PROBE_OUT != deleting ]]; then
      aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null
    fi
    info "banco $DB_ID em remoção, sem snapshot final; isso leva alguns minutos"
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
    info "banco $DB_ID removido"
  else
    gone "banco $DB_ID"
  fi
  if probe 'DBSubnetGroupNotFoundFault' aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP"; then
    aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"
    info "DB subnet group removido"
  fi
}

remove_ecr() {
  if probe 'RepositoryNotFoundException' aws ecr describe-repositories --repository-names "$ECR_REPO"; then
    aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null
    info "repositório ECR $ECR_REPO removido com as imagens"
  else
    gone "repositório ECR $ECR_REPO"
  fi
}

remove_bucket() {
  if ! probe '404|Not Found' aws s3api head-bucket --bucket "$BUCKET"; then
    gone "bucket $BUCKET"
    return
  fi
  local versions
  aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
  versions=$(aws s3api list-object-versions --bucket "$BUCKET" --output json |
    jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}')
  if [[ $(jq '.Objects | length' <<<"$versions") -gt 0 ]]; then
    aws s3api delete-objects --bucket "$BUCKET" --delete "$versions" >/dev/null
  fi
  aws s3api delete-bucket --bucket "$BUCKET"
  info "bucket $BUCKET removido"
}

remove_params() {
  aws ssm delete-parameters --names "$PARAM_DB_PASSWORD" "$PARAM_JWT_SECRET" >/dev/null
  info "parâmetros SSM removidos"
}

remove_logs() {
  if probe 'ResourceNotFoundException' aws logs delete-log-group --log-group-name "$LOG_GROUP"; then
    info "log group $LOG_GROUP removido"
  else
    gone "log group $LOG_GROUP"
  fi
}

remove_role() { # nome
  if ! probe 'NoSuchEntity' aws iam get-role --role-name "$1"; then
    gone "role $1"
    return
  fi
  local p attached=() inline=()
  mapfile -t attached < <(aws iam list-attached-role-policies --role-name "$1" \
    --query 'AttachedPolicies[].PolicyArn' --output text | list_lines)
  for p in "${attached[@]}"; do aws iam detach-role-policy --role-name "$1" --policy-arn "$p"; done
  mapfile -t inline < <(aws iam list-role-policies --role-name "$1" --query 'PolicyNames' --output text | list_lines)
  for p in "${inline[@]}"; do aws iam delete-role-policy --role-name "$1" --policy-name "$p"; done
  aws iam delete-role --role-name "$1"
  info "role $1 removida"
}

remove_roles() {
  remove_role "$EXEC_ROLE"
  remove_role "$GITHUB_ROLE"
}

env_vpc() {
  aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV_NAME" "Name=tag:Environment,Values=$ENV_NAME" \
    --query 'Vpcs[0].VpcId' --output text
}

# Interfaces das tasks e do RDS somem alguns minutos depois da remoção deles.
wait_enis() { # vpc-id
  local deadline=$((SECONDS + 900)) n
  while :; do
    n=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$1" --query 'length(NetworkInterfaces)' --output text)
    if ((n == 0)); then return 0; fi
    if ((SECONDS >= deadline)); then
      warn "$n interface(s) de rede ainda presentes na VPC"
      return 0
    fi
    info "aguardando a liberação de $n interface(s) de rede"
    sleep 20
  done
}

remove_network() {
  local vpc sg id rtb igw ids=()
  vpc=$(env_vpc)
  if [[ $vpc != None ]]; then
    wait_enis "$vpc"
    # O SG do banco referencia o da API, então sai primeiro.
    for sg in "$SG_DB" "$SG_API"; do
      id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=$sg" \
        --query 'SecurityGroups[0].GroupId' --output text)
      if [[ $id != None ]]; then retry 6 aws ec2 delete-security-group --group-id "$id"; fi
    done
    mapfile -t ids < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' \
      --output text | list_lines)
    for id in "${ids[@]}"; do retry 6 aws ec2 delete-subnet --subnet-id "$id"; done
    mapfile -t ids < <(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
      --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text | list_lines)
    for rtb in "${ids[@]}"; do aws ec2 delete-route-table --route-table-id "$rtb"; done
  fi
  mapfile -t ids < <(aws ec2 describe-internet-gateways --filters "Name=tag:Environment,Values=$ENV_NAME" \
    --query 'InternetGateways[].InternetGatewayId' --output text | list_lines)
  for igw in "${ids[@]}"; do
    if [[ $vpc != None ]]; then
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" 2>/dev/null || true
    fi
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
  if [[ $vpc != None ]]; then
    retry 6 aws ec2 delete-vpc --vpc-id "$vpc"
    info "VPC $vpc e rede removidas"
  else
    gone "VPC $ENV_NAME"
  fi
}

FAILED=()
# Cada etapa roda isolada com set -e; uma falha real é registrada e as demais continuam.
run_step() { # descrição função
  log "$1"
  set +e
  (
    set -e
    "$2"
  )
  local rc=$?
  set -e
  if ((rc != 0)); then
    FAILED+=("$1")
    warn "falha em: $1 (as próximas etapas continuam)"
  fi
}

count() { # consulta que devolve um número
  "$@" --output text 2>/dev/null || echo "?"
}

report_remnants() {
  local r=() vpc n
  probe 'DBInstanceNotFound' aws rds describe-db-instances --db-instance-identifier "$DB_ID" && r+=("banco $DB_ID")
  n=$(count aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" --query 'length(DBSnapshots)')
  [[ $n == 0 ]] || r+=("snapshots do banco ($n)")
  n=$(count aws rds describe-db-instance-automated-backups --db-instance-identifier "$DB_ID" \
    --query 'length(DBInstanceAutomatedBackups)')
  [[ $n == 0 || $n == "?" ]] || r+=("backups automáticos retidos ($n)")
  probe 'DBSubnetGroupNotFoundFault' aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" &&
    r+=("DB subnet group $DB_SUBNET_GROUP")
  [[ $(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text) != ACTIVE ]] ||
    r+=("cluster ECS $CLUSTER (e possíveis tasks)")
  n=$(task_definition_arns ACTIVE | wc -l)
  ((n == 0)) || r+=("task definitions ativas ($n)")
  vpc=$(env_vpc)
  if [[ $vpc != None ]]; then
    r+=("VPC $vpc")
    n=$(count aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" --query 'length(NetworkInterfaces)')
    [[ $n == 0 ]] || r+=("interfaces de rede/IPs públicos na VPC ($n)")
  fi
  n=$(count aws ec2 describe-internet-gateways --filters "Name=tag:Environment,Values=$ENV_NAME" \
    --query 'length(InternetGateways)')
  [[ $n == 0 ]] || r+=("internet gateways ($n)")
  n=$(count aws ec2 describe-addresses --filters "Name=tag:Environment,Values=$ENV_NAME" --query 'length(Addresses)')
  [[ $n == 0 ]] || r+=("IPs elásticos ($n)")
  probe 'RepositoryNotFoundException' aws ecr describe-repositories --repository-names "$ECR_REPO" && r+=("ECR $ECR_REPO")
  probe '404|Not Found' aws s3api head-bucket --bucket "$BUCKET" && r+=("bucket $BUCKET")
  n=$(count aws ssm describe-parameters --parameter-filters "Key=Name,Values=$PARAM_DB_PASSWORD,$PARAM_JWT_SECRET" \
    --query 'length(Parameters)')
  [[ $n == 0 ]] || r+=("parâmetros SSM ($n)")
  n=$(count aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)")
  [[ $n == 0 ]] || r+=("log group $LOG_GROUP")
  probe 'NoSuchEntity' aws iam get-role --role-name "$EXEC_ROLE" && r+=("role $EXEC_ROLE")
  probe 'NoSuchEntity' aws iam get-role --role-name "$GITHUB_ROLE" && r+=("role $GITHUB_ROLE")
  REMNANTS=("${r[@]}")
}

log "Marcando o laboratório como encerrado no GitHub (LAB_STATE=destroyed)"
gh variable set LAB_STATE --repo "$GITHUB_REPO" --body destroyed

run_step "ECS: serviço, tasks e cluster" remove_ecs
run_step "ECS: task definitions" remove_task_definitions
run_step "RDS: banco e subnet group" remove_database
run_step "ECR" remove_ecr
run_step "S3: site" remove_bucket
run_step "SSM: segredos" remove_params
run_step "CloudWatch Logs" remove_logs
run_step "IAM: roles do ambiente" remove_roles
run_step "Rede: security groups, sub-redes, rotas, internet gateway e VPC" remove_network

log "Conferência dos recursos remanescentes de $ENV_NAME"
REMNANTS=()
report_remnants
info "provedor OIDC $OIDC_HOST preservado (compartilhado pela conta)"
if ((${#REMNANTS[@]} == 0 && ${#FAILED[@]} == 0)); then
  log "Ambiente $ENV_NAME removido. Nenhum recurso remanescente encontrado."
  info "As cobranças podem aparecer no faturamento com atraso; confira o Billing nos próximos dias."
  exit 0
fi
((${#FAILED[@]} == 0)) || printf 'Etapas com falha: %s\n' "${FAILED[@]}" >&2
((${#REMNANTS[@]} == 0)) || printf 'Recurso remanescente (pode gerar custo): %s\n' "${REMNANTS[@]}" >&2
die "a remoção de $ENV_NAME não terminou; execute o script novamente ou remova os itens acima"
