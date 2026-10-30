#!/usr/bin/env bash
# Abre PRs para apontar outros repositórios ao preset central do Renovate.
# Não escreve na branch padrão, não faz merge e não altera engines.node.
# Os tetos abaixo espelham o preset: no máximo 2 PRs novos por hora,
# 3 PRs abertos e 3 branches. Sem isso, uma execução abre um PR por
# repositório e enche a fila de builds da Vercel.
set -uo pipefail

export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1

HEAD_BRANCH="chore-renovate-central-config"
PRESET="github>gustavoborgesc/renovate-config"
LIST_LIMIT=1000
PR_CONCURRENT_LIMIT=3
PR_HOURLY_LIMIT=2
BRANCH_CONCURRENT_LIMIT=3

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "erro: GH_TOKEN ausente. O workflow espera o secret PAT_GLOBAL." >&2
  exit 1
fi

if [[ -z "${SELF_REPO:-}" ]]; then
  echo "erro: SELF_REPO ausente." >&2
  exit 1
fi

log() { printf '%s\n' "$*"; }
warn() { printf 'aviso: %s\n' "$*" >&2; }
err() { printf 'erro: %s\n' "$*" >&2; }

run_gh() {
  command gh "$@" </dev/null
}

DESIRED_JSON="$(cat <<EOF
{
  "\$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "${PRESET}"
  ]
}
EOF
)"

if ! DESIRED_CANON="$(printf '%s\n' "$DESIRED_JSON" | jq -cS .)"; then
  err "JSON desejado do renovate.json é inválido"
  exit 1
fi
DESIRED_FILE="$(printf '%s\n' "$DESIRED_JSON" | jq .)"
DESIRED_B64="$(printf '%s\n' "$DESIRED_FILE" | base64 -w 0)"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
cat >"$BODY_FILE" <<'EOF'
Aponta o `renovate.json` para o preset central `github>gustavoborgesc/renovate-config`.

Este pull request substitui o arquivo inteiro por esse `extends`. Se o repositório tiver regra local que precise continuar valendo, edite o PR e mantenha a regra junto do `extends` antes de mergear.

A branch padrão não é alterada por este workflow. O merge fica para revisão humana. `engines.node` não é modificado.
EOF

assert_feature_branch() {
  local default_branch="$1"
  if [[ -z "$HEAD_BRANCH" || "$HEAD_BRANCH" == "$default_branch" ]]; then
    err "recusa: a branch de trabalho coincidiria com a branch padrão ($default_branch)"
    return 1
  fi
}

canon_from_contents() {
  local payload="$1"
  local b64
  b64="$(printf '%s' "$payload" | jq -er '.content')" || return 1
  printf '%s' "$b64" | tr -d '[:space:]' | base64 -d | jq -cS .
}

fetch_contents() {
  local repo="$1"
  local ref="$2"
  # Sem --method GET, o gh trata -f como corpo e muda o verbo para POST.
  run_gh api --method GET "/repos/${repo}/contents/renovate.json" -f "ref=${ref}"
}

ensure_feature_branch() {
  local repo="$1"
  local default_branch="$2"
  local base_payload base_sha

  assert_feature_branch "$default_branch" || return 1

  if run_gh api "/repos/${repo}/git/ref/heads/${HEAD_BRANCH}" >/dev/null 2>&1; then
    return 0
  fi

  base_payload="$(run_gh api "/repos/${repo}/git/ref/heads/${default_branch}")" || return 1
  base_sha="$(printf '%s' "$base_payload" | jq -er '.object.sha')" || return 1

  run_gh api --method POST "/repos/${repo}/git/refs" \
    -f "ref=refs/heads/${HEAD_BRANCH}" \
    -f "sha=${base_sha}" >/dev/null
}

write_feature_branch_file() {
  local repo="$1"
  local default_branch="$2"
  local file_sha="$3"

  assert_feature_branch "$default_branch" || return 1

  local -a args=(
    api
    --method PUT
    "/repos/${repo}/contents/renovate.json"
    -f "message=chore: apontar renovate.json para o preset central"
    -f "content=${DESIRED_B64}"
    -f "branch=${HEAD_BRANCH}"
  )
  if [[ -n "$file_sha" ]]; then
    args+=(-f "sha=${file_sha}")
  fi
  run_gh "${args[@]}" >/dev/null
}

OPEN_PRS=0
FEATURE_BRANCHES=0
CREATED_THIS_RUN=0
CREATED_THIS_HOUR=0
HOUR_PREFIX="$(date -u +%Y-%m-%dT%H)"

repo_in_scope() {
  local repo="$1"
  local default_branch="$2"
  [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
  [[ -n "$default_branch" && "$default_branch" != *$'\t'* && "$default_branch" != *" "* ]] || return 1
  [[ "${repo,,}" != "${SELF_REPO,,}" ]] || return 1
  return 0
}

pr_limit_reason() {
  local used
  if [[ "$OPEN_PRS" -ge "$PR_CONCURRENT_LIMIT" ]]; then
    printf 'prConcurrentLimit %s (abertos: %s)' "$PR_CONCURRENT_LIMIT" "$OPEN_PRS"
    return 0
  fi
  used=$((CREATED_THIS_HOUR + CREATED_THIS_RUN))
  if [[ "$used" -ge "$PR_HOURLY_LIMIT" ]]; then
    printf 'prHourlyLimit %s (nesta hora: %s)' "$PR_HOURLY_LIMIT" "$used"
    return 0
  fi
  return 1
}

inventory_repo() {
  local repo="$1"
  local default_branch="$2"
  local owner json open_count hour_count

  repo_in_scope "$repo" "$default_branch" || return 0

  if run_gh api "/repos/${repo}/git/ref/heads/${HEAD_BRANCH}" >/dev/null 2>&1; then
    FEATURE_BRANCHES=$((FEATURE_BRANCHES + 1))
  fi

  owner="${repo%%/*}"
  json="$(run_gh pr list --repo "$repo" --state open --base "$default_branch" --head "${owner}:${HEAD_BRANCH}" --json number,createdAt)" || return 1
  open_count="$(printf '%s' "$json" | jq -r 'length')" || return 1
  hour_count="$(printf '%s' "$json" | jq -r --arg hour "$HOUR_PREFIX" '[.[] | select((.createdAt // "") | startswith($hour))] | length')" || return 1
  OPEN_PRS=$((OPEN_PRS + open_count))
  CREATED_THIS_HOUR=$((CREATED_THIS_HOUR + hour_count))
}

process_repo() {
  local repo="$1"
  local default_branch="$2"
  local owner payload canon file_sha closed closed_json open_pr open_json

  if [[ ! "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    err "nome de repositório inesperado: ${repo}"
    return 1
  fi
  if [[ -z "$default_branch" || "$default_branch" == *$'\t'* || "$default_branch" == *" "* ]]; then
    err "branch padrão inesperada em ${repo}"
    return 1
  fi
  if [[ "${repo,,}" == "${SELF_REPO,,}" ]]; then
    log "Pulando ${repo} (este repositório)."
    return 0
  fi

  log "========================================="
  log "Processando ${repo} (${default_branch})..."

  payload=""
  canon=""
  file_sha=""
  if payload="$(fetch_contents "$repo" "$default_branch")"; then
    file_sha="$(printf '%s' "$payload" | jq -r '.sha // empty')"
    if canon="$(canon_from_contents "$payload")" && [[ "$canon" == "$DESIRED_CANON" ]]; then
      log "  renovate.json já está no preset central."
      return 0
    fi
  fi

  owner="${repo%%/*}"
  closed_json="$(run_gh pr list --repo "$repo" --state closed --base "$default_branch" --head "${owner}:${HEAD_BRANCH}" --json number)" || return 1
  closed="$(printf '%s' "$closed_json" | jq -r '.[0].number // empty')" || return 1
  if [[ -n "$closed" ]]; then
    log "  PR #${closed} foi fechado sem merge. Não vou reabrir nem recriar a branch."
    return 0
  fi

  local had_branch=0 reason
  if run_gh api "/repos/${repo}/git/ref/heads/${HEAD_BRANCH}" >/dev/null 2>&1; then
    had_branch=1
  fi

  if [[ "$had_branch" -eq 0 ]]; then
    if reason="$(pr_limit_reason)"; then
      log "  limite de PRs atingido (${reason}). Não crio branch nem PR."
      return 0
    fi
    if [[ "$FEATURE_BRANCHES" -ge "$BRANCH_CONCURRENT_LIMIT" ]]; then
      log "  limite de branches atingido (branchConcurrentLimit ${BRANCH_CONCURRENT_LIMIT}). Não crio ${HEAD_BRANCH}."
      return 0
    fi
    ensure_feature_branch "$repo" "$default_branch" || return 1
    FEATURE_BRANCHES=$((FEATURE_BRANCHES + 1))
  fi

  payload=""
  canon=""
  file_sha=""
  if payload="$(fetch_contents "$repo" "$HEAD_BRANCH")"; then
    file_sha="$(printf '%s' "$payload" | jq -r '.sha // empty')"
    canon="$(canon_from_contents "$payload" || true)"
  fi

  if [[ "$canon" != "$DESIRED_CANON" ]]; then
    write_feature_branch_file "$repo" "$default_branch" "$file_sha" || return 1
    log "  renovate.json gravado na branch ${HEAD_BRANCH}."
  else
    log "  branch ${HEAD_BRANCH} já tem o arquivo esperado."
  fi

  open_json="$(run_gh pr list --repo "$repo" --state open --base "$default_branch" --head "${owner}:${HEAD_BRANCH}" --json number)" || return 1
  open_pr="$(printf '%s' "$open_json" | jq -r '.[0].number // empty')" || return 1
  if [[ -n "$open_pr" ]]; then
    log "  PR #${open_pr} já está aberto."
    return 0
  fi

  if reason="$(pr_limit_reason)"; then
    log "  limite de PRs atingido (${reason}). A branch fica sem PR novo nesta execução."
    return 0
  fi

  run_gh pr create \
    --repo "$repo" \
    --base "$default_branch" \
    --head "$HEAD_BRANCH" \
    --title "chore: apontar o Renovate para o preset central" \
    --body-file "$BODY_FILE" >/dev/null || return 1
  OPEN_PRS=$((OPEN_PRS + 1))
  CREATED_THIS_RUN=$((CREATED_THIS_RUN + 1))
  log "  PR aberto contra ${default_branch}."
}

main() {
  local list count failures=0 repo default_branch

  if ! list="$(run_gh repo list --limit "$LIST_LIMIT" --no-archived --source --json nameWithOwner,defaultBranchRef)"; then
    err "não foi possível listar os repositórios do dono do token"
    exit 1
  fi

  list="$(printf '%s' "$list" | jq -r '.[] | select(.defaultBranchRef != null) | [.nameWithOwner, .defaultBranchRef.name] | @tsv')" || {
    err "resposta inesperada ao listar repositórios"
    exit 1
  }

  count=0
  if [[ -n "$list" ]]; then
    count="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  fi
  if [[ "$count" -eq "$LIST_LIMIT" ]]; then
    warn "a lista atingiu ${LIST_LIMIT} repositórios; o restante não entra nesta execução"
  fi

  if [[ -n "$list" ]]; then
    while IFS=$'\t' read -r repo default_branch; do
      [[ -z "$repo" ]] && continue
      if ! inventory_repo "$repo" "$default_branch"; then
        failures=$((failures + 1))
        err "falha ao inventariar ${repo}"
      fi
    done <<<"$list"
  fi

  if [[ "$failures" -gt 0 ]]; then
    err "${failures} repositório(s) falharam no inventário"
    exit 1
  fi

  log "Inventário: ${OPEN_PRS} PR(s) aberto(s), ${FEATURE_BRANCHES} branch(es) ${HEAD_BRANCH}, ${CREATED_THIS_HOUR} nesta hora UTC."

  if [[ -n "$list" ]]; then
    while IFS=$'\t' read -r repo default_branch; do
      [[ -z "$repo" ]] && continue
      if ! process_repo "$repo" "$default_branch"; then
        failures=$((failures + 1))
        err "falha em ${repo}"
      fi
    done <<<"$list"
  fi

  if [[ "$failures" -gt 0 ]]; then
    err "${failures} repositório(s) falharam"
    exit 1
  fi
  log "Manutenção concluída sem merge e sem escrita na branch padrão."
}

main "$@"
