#!/usr/bin/env bash
# Cobre o contrato do script: PR em branch de trabalho, nunca a branch padrão,
# nunca merge, nunca package.json / engines.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/maintain-repos.sh"

fail() {
  printf 'FALHOU: %s\n' "$*" >&2
  exit 1
}

assert_log_safe() {
  local log="$1"
  if grep -E '(^| )pr merge($| )|--admin|--force|package\.json|engines' "$log" >/dev/null; then
    fail "log contém operação proibida: $(grep -E '(^| )pr merge($| )|--admin|--force|package\.json|engines' "$log")"
  fi
}

new_case() {
  local name="$1"
  CASE_DIR="$(mktemp -d)"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/state"
  MOCK_LOG="$CASE_DIR/gh.log"
  export MOCK_LOG MOCK_DIR="$CASE_DIR/state" PATH="$CASE_DIR/bin:$PATH"
  export GH_TOKEN="test-token" SELF_REPO="gustavoborgesc/renovate-config"
  cat >"$CASE_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_LOG"

method=""
path=""
saw_field=0
declare -A field=()
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  token="${args[$i]}"
  case "$token" in
    --method)
      i=$((i + 1))
      method="${args[$i]}"
      ;;
    -f)
      saw_field=1
      i=$((i + 1))
      pair="${args[$i]}"
      key="${pair%%=*}"
      value="${pair#*=}"
      field["$key"]="$value"
      ;;
    /*)
      path="$token"
      ;;
  esac
  i=$((i + 1))
done
# O gh real promove a POST qualquer chamada com -f que não fixe o método.
if [[ -z "$method" ]]; then
  if [[ "$saw_field" -eq 1 ]]; then
    method="POST"
  else
    method="GET"
  fi
fi

repo_of_path() {
  local p="$1"
  printf '%s' "$p" | sed -E 's#^/repos/([^/]+/[^/]+)/.*#\1#'
}

if [[ "${args[0]}" == "repo" && "${args[1]}" == "list" ]]; then
  cat "$MOCK_DIR/repos.json"
  exit 0
fi

if [[ "${args[0]}" == "pr" && "${args[1]}" == "list" ]]; then
  repo=""; state="open"; head=""
  i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --repo) i=$((i + 1)); repo="${args[$i]}" ;;
      --state) i=$((i + 1)); state="${args[$i]}" ;;
      --head) i=$((i + 1)); head="${args[$i]}" ;;
    esac
    i=$((i + 1))
  done
  key="$(printf '%s' "$repo" | tr '/' '_')"
  if [[ "$state" == "closed" && -f "$MOCK_DIR/closed_$key" ]]; then
    printf '%s\n' '[{"number":41}]'
  elif [[ "$state" == "open" && -f "$MOCK_DIR/open_$key" ]]; then
    printf '%s\n' '[{"number":7}]'
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi

if [[ "${args[0]}" == "pr" && "${args[1]}" == "create" ]]; then
  base=""; head=""; repo=""
  i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --repo) i=$((i + 1)); repo="${args[$i]}" ;;
      --base) i=$((i + 1)); base="${args[$i]}" ;;
      --head) i=$((i + 1)); head="${args[$i]}" ;;
    esac
    i=$((i + 1))
  done
  if [[ -z "$head" || "$head" == "$base" || "$head" != "chore-renovate-central-config" ]]; then
    echo "mock: pr create com head inseguro ($head -> $base)" >&2
    exit 97
  fi
  printf '%s\n' "$head" >>"$MOCK_DIR/created-heads"
  touch "$MOCK_DIR/open_$(printf '%s' "$repo" | tr '/' '_')"
  exit 0
fi

if [[ "${args[0]}" == "pr" && "${args[1]}" == "merge" ]]; then
  echo "mock: merge proibido" >&2
  exit 98
fi

if [[ "${args[0]}" != "api" ]]; then
  echo "mock: comando gh não esperado: ${args[*]}" >&2
  exit 96
fi

repo="$(repo_of_path "$path")"
key="$(printf '%s' "$repo" | tr '/' '_')"
default_branch="$(cat "$MOCK_DIR/default_$key")"

if [[ "$method" == "POST" && "$path" == *"/contents/"* ]]; then
  echo "mock: POST em contents; leitura precisa de --method GET" >&2
  exit 91
fi

if [[ "$method" == "PUT" || "$method" == "POST" ]]; then
  target_branch="${field[branch]:-}"
  ref="${field[ref]:-}"
  if [[ "$path" == *"/contents/package.json" ]]; then
    echo "mock: escrita em package.json" >&2
    exit 95
  fi
  if [[ "$method" == "PUT" ]]; then
    if [[ -z "$target_branch" || "$target_branch" == "$default_branch" || "$target_branch" != "chore-renovate-central-config" ]]; then
      echo "mock: PUT na branch proibida ($target_branch, padrão $default_branch)" >&2
      exit 94
    fi
    mkdir -p "$MOCK_DIR/files"
    safe_ref="$(printf '%s' "$target_branch" | tr '/' '_')"
    printf '%s' "${field[content]}" | base64 -d >"$MOCK_DIR/files/${key}__${safe_ref}.json"
  fi
  if [[ "$method" == "POST" && "$path" == *"/git/refs" ]]; then
    case "$ref" in
      refs/heads/chore-renovate-central-config) ;;
      *)
        echo "mock: criação de ref proibida ($ref)" >&2
        exit 93
        ;;
    esac
    if [[ "${ref#refs/heads/}" == "$default_branch" ]]; then
      echo "mock: ref da branch padrão" >&2
      exit 92
    fi
    touch "$MOCK_DIR/branch_${key}"
  fi
  printf '%s\n' '{"ok":true}'
  exit 0
fi

if [[ "$path" == *"/contents/renovate.json" ]]; then
  ref="${field[ref]}"
  safe_ref="$(printf '%s' "$ref" | tr '/' '_')"
  file="$MOCK_DIR/files/${key}__${safe_ref}.json"
  if [[ ! -f "$file" ]]; then
    echo "not found" >&2
    exit 1
  fi
  b64="$(base64 -w 0 <"$file")"
  jq -n --arg content "$b64" --arg sha "sha-${ref}" '{sha:$sha, encoding:"base64", content:$content}'
  exit 0
fi

if [[ "$path" == *"/git/ref/heads/chore-renovate-central-config" ]]; then
  if [[ -f "$MOCK_DIR/branch_${key}" ]]; then
    printf '%s\n' '{"object":{"sha":"feature-sha"}}'
    exit 0
  fi
  echo "not found" >&2
  exit 1
fi

if [[ "$path" == *"/git/ref/heads/${default_branch}" ]]; then
  printf '%s\n' '{"object":{"sha":"base-sha"}}'
  exit 0
fi

echo "mock: GET não esperado $method $path" >&2
exit 90
MOCK
  chmod +x "$CASE_DIR/bin/gh"
  printf 'caso %s\n' "$name"
}

write_repos() {
  local json="$1"
  printf '%s\n' "$json" >"$MOCK_DIR/repos.json"
  printf '%s' "$json" | jq -r '.[] | select(.defaultBranchRef != null) | [.nameWithOwner, .defaultBranchRef.name] | @tsv' |
    while IFS=$'\t' read -r repo branch; do
      key="$(printf '%s' "$repo" | tr '/' '_')"
      printf '%s' "$branch" >"$MOCK_DIR/default_$key"
    done
}

safe_ref() {
  printf '%s' "$1" | tr '/' '_'
}

write_file_on() {
  local repo="$1"
  local branch="$2"
  local json="$3"
  local key
  key="$(printf '%s' "$repo" | tr '/' '_')"
  mkdir -p "$MOCK_DIR/files"
  printf '%s\n' "$json" >"$MOCK_DIR/files/${key}__$(safe_ref "$branch").json"
}

# shellcheck disable=SC2016 # $schema é texto do JSON, não expansão do shell
desired='{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>gustavoborgesc/renovate-config"]
}'

if grep -nE 'pr merge|--admin|--force' \
  "$ROOT/.github/workflows/global-maintenance.yml" "$SCRIPT"; then
  fail "workflow ou script ainda pede merge administrativo ou force-push"
fi

if grep -nE 'package\.json|engines' "$ROOT/.github/workflows/global-maintenance.yml"; then
  fail "workflow ainda mexe em package.json ou engines"
fi

if grep -nE ':automergeAll|:automergeBranch|:skipStatusChecks|"ignoreTests": true|"platformAutomerge": true|"automergeType": "branch"' \
  "$ROOT/default.json"; then
  fail "preset ainda tem automerge inseguro"
fi

jq -e '
  [.. | objects | select(.automerge == true) | select(
    ((.matchUpdateTypes // []) | index("major")) != null
    or (((.matchUpdateTypes // []) | index("patch")) == null and ((.matchUpdateTypes // []) | index("minor")) == null)
  )] | length == 0
' "$ROOT/default.json" >/dev/null || fail "há automerge fora de patch/minor"

jq -e '
  [.. | objects | select((.matchUpdateTypes // []) | index("major")) | select(.automerge != false)] | length == 0
' "$ROOT/default.json" >/dev/null || fail "major não está com automerge false"

new_case "já configurado"
write_repos '[{"nameWithOwner":"acme/ok","defaultBranchRef":{"name":"main"}},{"nameWithOwner":"gustavoborgesc/renovate-config","defaultBranchRef":{"name":"main"}}]'
write_file_on "acme/ok" "main" "$desired"
bash "$SCRIPT" >"$CASE_DIR/out.txt"
assert_log_safe "$MOCK_LOG"
grep -q "já está no preset central" "$CASE_DIR/out.txt"
grep -q "Pulando gustavoborgesc/renovate-config" "$CASE_DIR/out.txt"
if grep -q "contents/renovate.json" "$MOCK_LOG" && grep -q -- "--method PUT" "$MOCK_LOG"; then
  fail "repositório já configurado não deveria receber PUT"
fi
if [[ -f "$MOCK_DIR/created-heads" ]]; then
  fail "não deveria abrir PR"
fi

new_case "arquivo ausente abre PR na branch de trabalho"
write_repos '[{"nameWithOwner":"acme/missing","defaultBranchRef":{"name":"develop"}}]'
bash "$SCRIPT" >"$CASE_DIR/out.txt"
assert_log_safe "$MOCK_LOG"
grep -q "PR aberto contra develop" "$CASE_DIR/out.txt"
[[ "$(cat "$MOCK_DIR/created-heads")" == "chore-renovate-central-config" ]]
bash "$SCRIPT" >"$CASE_DIR/second.txt"
assert_log_safe "$MOCK_LOG"
grep -q "já está aberto" "$CASE_DIR/second.txt"
[[ "$(wc -l <"$MOCK_DIR/created-heads" | tr -d ' ')" == "1" ]]
written="$(jq -cS . "$MOCK_DIR/files/acme_missing__chore-renovate-central-config.json")"
expected="$(printf '%s\n' "$desired" | jq -cS .)"
[[ "$written" == "$expected" ]]
if grep -q "branch=develop" "$MOCK_LOG"; then
  fail "houve escrita citando a branch padrão"
fi

new_case "json diferente vira PR e PR fechado não reabre"
write_repos '[{"nameWithOwner":"acme/custom","defaultBranchRef":{"name":"main"}}]'
write_file_on "acme/custom" "main" '{"extends":["config:recommended"]}'
bash "$SCRIPT" >"$CASE_DIR/out.txt"
assert_log_safe "$MOCK_LOG"
grep -q "PR aberto contra main" "$CASE_DIR/out.txt"

new_case "PR fechado é respeitado"
write_repos '[{"nameWithOwner":"acme/closed","defaultBranchRef":{"name":"main"}}]'
write_file_on "acme/closed" "main" '{"extends":["elsewhere"]}'
touch "$MOCK_DIR/closed_acme_closed"
bash "$SCRIPT" >"$CASE_DIR/out.txt"
assert_log_safe "$MOCK_LOG"
grep -q "fechado sem merge" "$CASE_DIR/out.txt"
if [[ -f "$MOCK_DIR/created-heads" || -f "$MOCK_DIR/files/acme_closed__chore-renovate-central-config.json" ]]; then
  fail "PR fechado não deveria ser recriado"
fi

new_case "PR aberto não é duplicado"
write_repos '[{"nameWithOwner":"acme/open","defaultBranchRef":{"name":"trunk"}}]'
write_file_on "acme/open" "trunk" '{"extends":["elsewhere"]}'
write_file_on "acme/open" "chore-renovate-central-config" "$desired"
touch "$MOCK_DIR/branch_acme_open" "$MOCK_DIR/open_acme_open"
bash "$SCRIPT" >"$CASE_DIR/out.txt"
assert_log_safe "$MOCK_LOG"
grep -q "PR #7 já está aberto" "$CASE_DIR/out.txt"
if [[ -f "$MOCK_DIR/created-heads" ]]; then
  fail "PR aberto foi duplicado"
fi

new_case "branch padrão igual à branch de trabalho falha sem escrever"
write_repos '[{"nameWithOwner":"acme/clash","defaultBranchRef":{"name":"chore-renovate-central-config"}}]'
set +e
bash "$SCRIPT" >"$CASE_DIR/out.txt" 2>"$CASE_DIR/err.txt"
status=$?
set -e
[[ "$status" -ne 0 ]]
assert_log_safe "$MOCK_LOG"
grep -q "coincidiria com a branch padrão" "$CASE_DIR/err.txt"
if [[ -f "$MOCK_DIR/created-heads" ]]; then
  fail "conflito de nome de branch não deveria abrir PR"
fi

printf 'testes do script ok\n'
