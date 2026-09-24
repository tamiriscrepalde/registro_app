#!/usr/bin/env bash
# Testes dos scripts de infraestrutura sem acesso à AWS: argumentos, nomes, policies IAM e task definition.
# Uso: scripts/tests/run.sh
# shellcheck disable=SC2016 # filtros jq e trechos bash -c usam $ literal de propósito
set -Eeuo pipefail
shopt -s inherit_errexit
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

PASS=0 FAIL=0
pass() {
  PASS=$((PASS + 1))
  printf 'ok      %s\n' "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf 'FALHOU  %s\n' "$1"
  [[ -z ${2:-} ]] || printf '        %s\n' "${2:0:400}"
}
# Cada verificação é uma única expressão; o código de saída dela decide o resultado.
check() { # descrição comando...
  local d=$1 out
  shift
  if out=$("$@" 2>&1); then pass "$d"; else fail "$d" "$out"; fi
}
json() { # descrição documento filtro-jq [args-jq...]
  local d=$1 doc=$2 filter=$3
  shift 3
  check "$d" jq -e "$@" "$filter" <<<"$doc"
}
expect_fail() { # descrição padrão-da-mensagem comando...
  local d=$1 pattern=$2 out rc=0
  shift 2
  out=$("$@" 2>&1) || rc=$?
  if ((rc != 0)) && grep -Eq "$pattern" <<<"$out"; then pass "$d"; else fail "$d" "rc=$rc: $out"; fi
}

OWNER=tester
set_names lab-test us-east-1 123456789012
SUB='repo:owner@1/repo@2:environment:lab-test'
TRUST=$(policy_github_trust "$SUB")
DEPLOY=$(policy_github_deploy)
EXEC_TRUST=$(policy_ecs_exec_trust)
SECRETS=$(policy_ecs_exec_secrets)
SITE_POLICY=$(policy_site_bucket)
IMAGE_URI=123456789012.dkr.ecr.us-east-1.amazonaws.com/lab-test-api@sha256:$(printf '%064d' 0)
DB_HOST=lab-test-db.abc.us-east-1.rds.amazonaws.com
IMAGE_TAG=0123456789abcdef
TASKDEF=$(task_definition_json)

echo "# nomes e argumentos"
check "endpoint do site em us-east-1 usa hífen" \
  test "$(site_url b us-east-1)" = "http://b.s3-website-us-east-1.amazonaws.com"
check "endpoint do site em eu-central-1 usa ponto" \
  test "$(site_url b eu-central-1)" = "http://b.s3-website.eu-central-1.amazonaws.com"
check "aceita o identificador lab-deploy" validate_env_name lab-deploy
for bad in Lab_Deploy ab lab- 1lab lab.deploy; do
  expect_fail "rejeita o identificador '$bad'" 'ambiente inválido' validate_env_name "$bad"
done
expect_fail "rejeita conta com formato errado" 'conta AWS inválida' validate_account 12345
check "nomes cabem nos limites da AWS com o maior identificador aceito" bash -c '
  source scripts/lib.sh; set_names "a2345678901234567890123" us-east-1 123456789012
  (( ${#BUCKET} <= 63 && ${#GITHUB_ROLE} <= 64 && ${#EXEC_ROLE} <= 64 ))'

expect_fail "deploy.sh sem argumentos falha" 'obrigatórios' scripts/deploy.sh
expect_fail "deploy.sh recusa ambiente inválido" 'ambiente inválido' \
  scripts/deploy.sh --env X --region us-east-1 --account 123456789012 --image-tag abc
expect_fail "deploy.sh exige --provision ou --image-tag" 'informe --provision' \
  scripts/deploy.sh --env lab-test --region us-east-1 --account 123456789012
expect_fail "deploy.sh --provision exige --github-repo" 'github-repo' \
  scripts/deploy.sh --env lab-test --region us-east-1 --account 123456789012 --provision
expect_fail "deploy.sh recusa opção sem valor" 'precisa de um valor' scripts/deploy.sh --env --region us-east-1
expect_fail "destroy.sh sem argumentos falha" 'obrigatórios' scripts/destroy.sh
expect_fail "destroy.sh exige --github-repo" 'github-repo' \
  scripts/destroy.sh --env lab-test --region us-east-1 --account 123456789012
check "deploy.sh --help documenta o uso" bash -c 'scripts/deploy.sh --help | grep -q -- "--provision"'
check "destroy.sh --help documenta a opção não interativa" bash -c 'scripts/destroy.sh --help | grep -q -- "--yes"'
check "scripts têm interpretador bash e permissão de execução" bash -c '
  for f in scripts/deploy.sh scripts/destroy.sh scripts/tests/run.sh; do
    [[ -x $f && $(head -1 "$f") == "#!/usr/bin/env bash" ]] || exit 1
  done'
# Ignora strings e comentários: procura só comandos de remoção ou chamadas ao destroy.sh.
check "deploy.sh não remove recursos nem chama o destroy.sh" bash -c '
  ! sed -E -e "s/\x27[^\x27]*\x27//g" -e "s/\"[^\"]*\"//g" -e "s/(^|[[:space:]])#.*$//" scripts/deploy.sh |
    grep -nE "(aws [a-z0-9-]+ (delete|deregister|terminate|remove|detach|revoke)|destroy\.sh)"'

echo "# trust e permissões da role do CI"
json "trust aceita só o subject exato com audience do STS" "$TRUST" '
  (.Statement | length) == 1 and .Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
  and .Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  and .Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == $sub
  and .Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
  and (.Statement[0].Condition | has("StringLike") | not)' --arg sub "$SUB"
json "policy do CI não usa ações com curinga" "$DEPLOY" '
  [.Statement[].Action | if type == "array" then .[] else . end] | all(contains("*") | not)'
json "Resource \"*\" só em ações sem nível de recurso ou restritas ao cluster" "$DEPLOY" '
  ["ecr:GetAuthorizationToken", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
   "ec2:DescribeNetworkInterfaces", "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition",
   "ssm:DescribeParameters", "logs:DescribeLogGroups"] as $allow
  | [.Statement[] | select(.Resource == "*")
     | select(.Condition.ArnEquals["ecs:cluster"] != "arn:aws:ecs:us-east-1:123456789012:cluster/lab-test") | .Action[]]
  | all(. as $a | $allow | index($a))'
json "CI não cria nem remove infraestrutura e não lê segredos" "$DEPLOY" '
  [.Statement[].Action[]] | all(test("^(iam:(Create|Delete|Put|Attach|Update|Tag)|ec2:(Create|Delete|Authorize|Revoke|Modify|Run)|rds:(Create|Delete|Modify|Reboot)|s3:(DeleteBucket|PutBucket|CreateBucket)|ssm:(Get|Put|Delete)|secretsmanager:|kms:|ecr:(Create|Delete|SetRepositoryPolicy)|ecs:(Delete|Deregister|StopTask))") | not)'
json "iam:PassRole só da role de execução e só para o ECS" "$DEPLOY" '
  [.Statement[] | select(.Action | index("iam:PassRole"))]
  | length == 1 and .[0].Resource == "arn:aws:iam::123456789012:role/lab-test-ecs-exec"
  and .[0].Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com"'
json "recursos da policy do CI pertencem ao ambiente e à conta" "$DEPLOY" '
  [.Statement[].Resource | if type == "array" then .[] else . end | select(. != "*")]
  | all(contains("lab-test") and (startswith("arn:aws:s3:::") or contains(":123456789012:")))'
json "RunTask limitado à família da API no cluster do ambiente" "$DEPLOY" '
  .Statement[] | select(.Action == ["ecs:RunTask"])
  | .Resource == "arn:aws:ecs:us-east-1:123456789012:task-definition/lab-test-api:*"
  and .Condition.ArnEquals["ecs:cluster"] == "arn:aws:ecs:us-east-1:123456789012:cluster/lab-test"'

echo "# role de execução, bucket e task definition"
json "role de execução só é assumida pelo ECS da própria conta" "$EXEC_TRUST" '
  .Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
  and .Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"'
json "task lê apenas os dois segredos do ambiente" "$SECRETS" '
  (.Statement | length) == 1 and .Statement[0].Action == ["ssm:GetParameters"]
  and (.Statement[0].Resource | sort) == [
    "arn:aws:ssm:us-east-1:123456789012:parameter/lab-test/db-password",
    "arn:aws:ssm:us-east-1:123456789012:parameter/lab-test/jwt-secret"]'
json "bucket público só para s3:GetObject nos objetos do site" "$SITE_POLICY" '
  (.Statement | length) == 1 and .Statement[0].Principal == "*" and .Statement[0].Action == "s3:GetObject"
  and .Statement[0].Resource == "arn:aws:s3:::lab-test-site-123456789012/*"'
for doc in TRUST DEPLOY EXEC_TRUST SECRETS SITE_POLICY; do
  json "$doc tem Version 2012-10-17" "${!doc}" '.Version == "2012-10-17"'
done
json "imagem fixada por digest" "$TASKDEF" '.containerDefinitions[0].image | test("@sha256:[0-9a-f]{64}$")'
json "segredos vêm do SSM e não aparecem nas variáveis" "$TASKDEF" '
  .containerDefinitions[0] as $c
  | ([$c.secrets[].name] | sort) == ["JWT_SECRET", "PGPASSWORD"]
  and ($c.secrets | all(.valueFrom | startswith("arn:aws:ssm:us-east-1:123456789012:parameter/lab-test/")))
  and ([$c.environment[].name] | (index("PGPASSWORD") or index("JWT_SECRET") or index("DATABASE_URL")) | not)'
json "conexão com o RDS exige TLS e CORS usa a origem do site" "$TASKDEF" '
  (.containerDefinitions[0].environment | from_entries) as $e
  | $e.DB_SSL == "true" and $e.CORS_ORIGIN == $site and $e.PGHOST == $db and $e.APP_VERSION == "0123456789abcdef"' \
  --arg site "$SITE_URL" --arg db "$DB_HOST"
json "health check do container consulta /api/health" "$TASKDEF" '
  .containerDefinitions[0].healthCheck.command[1] | contains("http://127.0.0.1:3000/api/health")'
json "Fargate 0,25 vCPU/512 MiB, awsvpc, init process e logs no grupo do ambiente" "$TASKDEF" '
  .cpu == "256" and .memory == "512" and .networkMode == "awsvpc" and .requiresCompatibilities == ["FARGATE"]
  and .containerDefinitions[0].linuxParameters.initProcessEnabled == true
  and .containerDefinitions[0].logConfiguration.options["awslogs-group"] == "/ecs/lab-test"'
json "lifecycle do ECR limita as imagens guardadas" "$(policy_ecr_lifecycle)" \
  '.rules[0].selection.countNumber == 10 and .rules[0].action.type == "expire"'

printf '\n%d ok, %d falha(s)\n' "$PASS" "$FAIL"
((FAIL == 0))
