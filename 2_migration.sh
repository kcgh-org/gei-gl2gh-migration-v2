#!/usr/bin/env bash

set -o pipefail

# ============================================================
# GitLab -> GitHub parallel migration runner
# - ADO2GH-style status bar
# - Live log streaming
# - Generates migration status CSV
# - Generates repos_with_status.csv for downstream stages
# ============================================================

############################################
# Defaults
############################################
LOG_DIR="$PWD/logs/2_migration"
REPO_LOG_DIR="$LOG_DIR/repository-migration-logs"

OUTPUT_DIR="$PWD/output_files/migration"

CSV_PATH="${INVENTORY_FILE:-projects.csv}"
MAX_CONCURRENT=10
OUTPUT_PATH=""
timestamp="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$LOG_DIR" "$REPO_LOG_DIR" "$OUTPUT_DIR"
existing_octoshift_logs=$(find "$PWD" -maxdepth 1 -type f \
  \( -name "*.octoshift.log" -o -name "*.octoshift.verbose.log" \) \
  -printf "%f\n" 2>/dev/null || true)
  
# ROOT_DIR="${CI_PROJECT_DIR:-$(pwd)}"
# LOG_DIR="$ROOT_DIR/logs"
# VERBOSE_DIR="$LOG_DIR/gl2gh-verbose-logs"
# mkdir -p "$VERBOSE_DIR"
# mkdir -p "$LOG_DIR" "$OUTPUT_DIR"

RUN_LOG="$LOG_DIR/gl2gh-migrate-repos-${timestamp}.log"
REPOS_WITH_STATUS_CSV="$OUTPUT_DIR/repos_with_status.csv"

############################################
# Logging
############################################
log() {
  local msg="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
  echo "$msg"
  echo "$msg" >> "$RUN_LOG"
}

fail() {
  log "[ERROR] $*"
  exit 1
}

############################################
# Helpers
############################################
trim() {
  local value="${1:-}"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_url() {
  local url
  url="$(trim "${1:-}")"

  if [[ -z "$url" ]]; then
    printf ''
    return 0
  fi

  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="https://$url"
  fi

  url="${url%/}"
  printf '%s' "$url"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "$name is required"
}

extract_migration_id() {
  local file="$1"
  local migration_id=""

  migration_id="$(
    grep -Eio 'Migration[[:space:]]+ID[:[:space:]]*[A-Za-z0-9_-]+' "$file" 2>/dev/null \
      | tail -n1 \
      | sed -E 's/Migration[[:space:]]+ID[:[:space:]]*//I' \
      || true
  )"

  if [[ -z "$migration_id" ]]; then
   migration_id="$(
      grep -Eio 'Migration[[:space:]]+in[[:space:]]+progress[[:space:]]+\(ID:[[:space:]]*[A-Za-z0-9_-]+\)' "$file" 2>/dev/null \
        | tail -n1 \
        | sed -E 's/.*\(ID:[[:space:]]*([A-Za-z0-9_-]+)\).*/\1/I' \
        || true
    )"
  fi

  if [[ -z "$migration_id" ]]; then
    migration_id="$(
      grep -Eio 'migrationId[=:[:space:]]*[A-Za-z0-9_-]+' "$file" 2>/dev/null \
        | tail -n1 \
        | sed -E 's/migrationId[=:[:space:]]*//I' \
        || true
    )"
  fi

  printf '%s' "$migration_id"
}

############################################
# CLI args
############################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-concurrent)
      MAX_CONCURRENT="$2"; shift 2;;
    --csv)
      CSV_PATH="$2"; shift 2;;
    --output)
      OUTPUT_PATH="$2"; shift 2;;
    -*|--*)
      fail "Unknown option: $1";;
    *)
      fail "Unexpected positional arg: $1";;
  esac
done

############################################
# Validate inputs
############################################
require_cmd gh
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd python3

require_env GITLAB_PAT
require_env GH_PAT

GITLAB_SERVER_URL="${GITLAB_SERVER_URL:-https://gitlab.com}"
GITLAB_SERVER_URL="$(normalize_url "$GITLAB_SERVER_URL")"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_API_URL="$(normalize_url "$GITHUB_API_URL")"

if [[ "$GITHUB_API_URL" =~ ^https://api\.github\.com/?$ ]]; then
  log "[INFO] Migration destination : GitHub Enterprise Cloud"
elif [[ "$GITHUB_API_URL" =~ ^https://api\.[a-zA-Z0-9.-]+\.ghe\.com/?$ ]]; then
  log "[INFO] Migration destination : GitHub Enterprise Cloud Data Residency"
else
  fail "Invalid GITHUB_API_URL: $GITHUB_API_URL"
fi

if [[ -z "${MAX_CONCURRENT}" || ! "${MAX_CONCURRENT}" =~ ^[0-9]+$ ]]; then
  fail "--max-concurrent must be an integer"
fi

if [[ "${MAX_CONCURRENT}" -lt 1 ]]; then
  fail "--max-concurrent must be at least 1"
fi

if [[ "${MAX_CONCURRENT}" -gt 10 ]]; then
  fail "Maximum concurrent migrations (${MAX_CONCURRENT}) exceeds the allowed limit of 10. Please set --max-concurrent to 10 or less."
fi

sed -i 's/\r$//' "${CSV_PATH}" 2>/dev/null || true

[[ -f "${CSV_PATH}" ]] || fail "CSV file not found: ${CSV_PATH}"
[[ -s "${CSV_PATH}" ]] || fail "CSV file is empty: ${CSV_PATH}"

if [[ -z "${OUTPUT_PATH}" ]]; then
  OUTPUT_CSV_PATH="$OUTPUT_DIR/gl2gh_migration_output-${timestamp}.csv"
else
  OUTPUT_CSV_PATH="${OUTPUT_PATH}"
fi

export GH_PAT
export GH_TOKEN="$GH_PAT"
export GL_PAT="$GITLAB_PAT"

############################################
# CSV helpers
############################################
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next

  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"

    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'
          ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done

  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

normalize_header_name() {
  local s="$1"
  s="$(strip_quotes "$s")"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="${s//-/_}"
  s="${s// /_}"
  printf '%s' "$s"
}

############################################
# Header mapping
############################################
read -r HEADER_LINE < "${CSV_PATH}"
mapfile -t HEADER_FIELDS < <(parse_csv_line "${HEADER_LINE}")

declare -A COLIDX=()
for idx in "${!HEADER_FIELDS[@]}"; do
  name="$(normalize_header_name "${HEADER_FIELDS[$idx]}")"
  COLIDX["$name"]="$idx"
done

required_columns=(group_path project url github_org github_repo gh_repo_visibility)

missing=()
for col in "${required_columns[@]}"; do
  [[ -n "${COLIDX[$col]:-}" ]] || missing+=("$col")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  fail "CSV missing required columns: ${missing[*]}"
fi

############################################
# Status CSV writers
############################################
write_migration_status_csv_header() {
  echo "gitlab_group,gitlab_project,github_org,github_repo,gh_repo_visibility,Migration_Status,Log_File" > "${OUTPUT_CSV_PATH}"
}

append_status_row() {
  printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "${OUTPUT_CSV_PATH}"
}

update_repo_status_in_csv() {
  local target_org="$1"
  local target_repo="$2"
  local new_status="$3"
  local log_file="$4"
  local tmp
  tmp="$(mktemp)"

  {
    head -n 1 "${OUTPUT_CSV_PATH}"
    tail -n +2 "${OUTPUT_CSV_PATH}" \
    | while IFS= read -r line; do
        mapfile -t F < <(parse_csv_line "${line}")

        local gitlab_group gitlab_project github_org github_repo visibility status cur_log
        gitlab_group="$(strip_quotes "${F[0]:-}")"
        gitlab_project="$(strip_quotes "${F[1]:-}")"
        github_org="$(strip_quotes "${F[2]:-}")"
        github_repo="$(strip_quotes "${F[3]:-}")"
        visibility="$(strip_quotes "${F[4]:-}")"
        status="$(strip_quotes "${F[5]:-}")"
        cur_log="$(strip_quotes "${F[6]:-}")"

        if [[ "${github_org}" == "${target_org}" && "${github_repo}" == "${target_repo}" ]]; then
          printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
            "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" \
            "${visibility}" "${new_status}" "${log_file}"
        else
          printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
            "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" \
            "${visibility}" "${status}" "${cur_log}"
        fi
      done
  } > "${tmp}"

  mv "${tmp}" "${OUTPUT_CSV_PATH}"
}

############################################
# Build common GL2GH args
############################################
build_common_args() {
  COMMON_ARGS=()

  COMMON_ARGS+=(--gitlab-server-url "$GITLAB_SERVER_URL")
  COMMON_ARGS+=(--github-pat "$GH_PAT")
  COMMON_ARGS+=(--gitlab-pat "$GITLAB_PAT")
  COMMON_ARGS+=(--target-api-url "$GITHUB_API_URL")

  STORAGE_TYPE="$(echo "${STORAGE_TYPE:-GITHUB}" | tr '[:lower:]' '[:upper:]')"
  TARGET_UPLOAD_URL="$(normalize_url "${TARGET_UPLOAD_URL:-}")"

  if [[ "$STORAGE_TYPE" == "GITHUB" ]]; then
    if [[ "$GITHUB_API_URL" =~ ^https://api\.([a-zA-Z0-9.-]+)\.ghe\.com/?$ ]]; then
      if [[ -z "$TARGET_UPLOAD_URL" ]]; then
        ghe_subdomain="${BASH_REMATCH[1]}"
        TARGET_UPLOAD_URL="https://uploads.${ghe_subdomain}.ghe.com"

        log "[INFO] TARGET_UPLOAD_URL is not configured."
        log "[INFO] Auto-generated TARGET_UPLOAD_URL for GitHub Enterprise Cloud Data Residency: ${TARGET_UPLOAD_URL}"
      else
        log "[INFO] Using configured TARGET_UPLOAD_URL: ${TARGET_UPLOAD_URL}"
      fi
    fi
  fi

  case "$STORAGE_TYPE" in
    GITHUB)
      COMMON_ARGS+=(--use-github-storage)

      if [[ -n "$TARGET_UPLOAD_URL" ]]; then
        COMMON_ARGS+=(--target-uploads-url "$TARGET_UPLOAD_URL")
      fi
      ;;

    AZURE)
      require_env AZURE_STORAGE_CONNECTION_STRING
      COMMON_ARGS+=(--azure-storage-connection-string "$AZURE_STORAGE_CONNECTION_STRING")
      ;;
    AWS)
      require_env AWS_BUCKET_NAME
      require_env AWS_REGION
      require_env AWS_ACCESS_KEY_ID
      require_env AWS_SECRET_ACCESS_KEY
      COMMON_ARGS+=(
        --aws-bucket-name "$AWS_BUCKET_NAME"
        --aws-region "$AWS_REGION"
        --aws-access-key "$AWS_ACCESS_KEY_ID"
        --aws-secret-key "$AWS_SECRET_ACCESS_KEY"
      )
      if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
        COMMON_ARGS+=(--aws-session-token "$AWS_SESSION_TOKEN")
      fi
      ;;
    *)
      fail "Invalid STORAGE_TYPE: $STORAGE_TYPE. Valid values: GITHUB, AZURE, AWS"
      ;;
  esac

  SKIP_SSL_VERIFY="$(echo "${SKIP_SSL_VERIFY:-N}" | tr '[:lower:]' '[:upper:]')"
  case "$SKIP_SSL_VERIFY" in
    Y|YES)
      COMMON_ARGS+=(--no-ssl-verify)
      ;;
  esac

  if [[ "${GITLAB_DEBUG:-false}" == "true" ]]; then
    COMMON_ARGS+=(--gitlab-debug)
    COMMON_ARGS+=(--verbose)
  fi
}

############################################
# Migration function
############################################
migrate_repository() {
  local gitlab_group="$1"
  local gitlab_project="$2"
  local github_org="$3"
  local github_repo="$4"
  local gh_repo_visibility="$5"
  local log_file="$6"

  {
    printf '[%s] [START] Migration: %s/%s -> %s/%s (gh_repo_visibility: %s)\n' \
      "$(date)" "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" "${gh_repo_visibility}"

    printf '[%s] [INFO] Submitting migration request for %s/%s\n' \
      "$(date)" "${github_org}" "${github_repo}"

    gh gl2gh migrate-repo \
      "${COMMON_ARGS[@]}" \
      --gitlab-group "${gitlab_group}" \
      --gitlab-project "${gitlab_project}" \
      --github-org "${github_org}" \
      --github-repo "${github_repo}" \
      --target-repo-visibility "${gh_repo_visibility}" >> "${log_file}" 2>&1

    local migration_id
    migration_id="$(extract_migration_id "$log_file")"

    if [[ -n "$migration_id" ]]; then
      printf '[%s] [INFO] Migration ID: %s\n' "$(date)" "$migration_id" >> "${log_file}"
    fi

    if grep -q "No operation will be performed" "${log_file}" 2>/dev/null; then
      printf '[%s] [FAILED] No operation performed - repository may already exist or migration was skipped\n' "$(date)" >> "${log_file}"
      return 1
    fi
    
    if ! grep -q "State: SUCCEEDED" "${log_file}" 2>/dev/null; then
      printf '[%s] [FAILED] Migration did not reach SUCCEEDED state\n' "$(date)" >> "${log_file}"
      return 1
    fi
    
    printf '[%s] [SUCCESS] Migration: %s/%s -> %s/%s\n' \
      "$(date)" "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" >> "${log_file}"
    
    return 0
  } >> "${log_file}" 2>&1
}

############################################
# Queue and tracking
############################################
declare -A JOB_PIDS=()
declare -A JOB_LOGS=()
declare -A JOB_REPOS=()
declare -A JOB_ORGS=()
declare -A JOB_LASTLEN=()

QUEUE=()
MIGRATED=()
FAILED=()
SKIPPED=0

build_common_args

log "============================================================"
log "GitLab to GitHub migration using gh gl2gh migrate-repo"
log "============================================================"
log "[INFO] CSV_PATH              : $CSV_PATH"
log "[INFO] GITLAB_SERVER_URL     : $GITLAB_SERVER_URL"
log "[INFO] GITHUB_API_URL        : $GITHUB_API_URL"
log "[INFO] MAX_CONCURRENT        : $MAX_CONCURRENT"
log "[INFO] STORAGE_TYPE          : ${STORAGE_TYPE:-GITHUB}"
log "[INFO] Output CSV            : $OUTPUT_CSV_PATH"

############################################
# Load queue from CSV rows
############################################
LINE_NUM=0

while IFS= read -r line || [[ -n "$line" ]]; do
  ((LINE_NUM++))
  [[ ${LINE_NUM} -eq 1 ]] && continue

  [[ -z "$(trim "$line")" ]] && continue

  mapfile -t F < <(parse_csv_line "${line}")

  gitlab_group="$(strip_quotes "${F[${COLIDX[group_path]}]:-}")"
  gitlab_project="$(strip_quotes "${F[${COLIDX[project]}]:-}")"
  full_url="$(strip_quotes "${F[${COLIDX[url]}]:-}")"
  github_org="$(strip_quotes "${F[${COLIDX[github_org]}]:-}")"
  github_repo="$(strip_quotes "${F[${COLIDX[github_repo]}]:-}")"
  gh_repo_visibility="$(strip_quotes "${F[${COLIDX[gh_repo_visibility]}]:-}")"

  if [[ -n "$full_url" ]]; then
    clean_url="${full_url%%\?*}"
    clean_url="${clean_url%.git}"
    path_part="$(echo "$clean_url" | sed -E 's#https?://[^/]+/##')"

    gitlab_group="$(dirname "$path_part")"
    gitlab_project="$(basename "$path_part")"
  fi

  if [[ -z "$gitlab_group" || -z "$gitlab_project" || -z "$github_org" || -z "$github_repo" || -z "$gh_repo_visibility" ]]; then
    echo "[WARNING] Skipping malformed line ${LINE_NUM}: missing required values"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  QUEUE+=("${gitlab_group},${gitlab_project},${github_org},${github_repo},${gh_repo_visibility}")
done < "${CSV_PATH}"

############################################
# Initialize output CSV with Pending
############################################
write_migration_status_csv_header

for item in "${QUEUE[@]}"; do
  IFS=',' read -r gitlab_group gitlab_project github_org github_repo gh_repo_visibility <<< "${item}"
  append_status_row "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "Pending" ""
done

echo "[INFO] Starting migration with ${MAX_CONCURRENT} concurrent jobs..."
echo "[INFO] Processing ${#QUEUE[@]} repositories from: ${CSV_PATH}"
echo "[INFO] Initialized migration status output: ${OUTPUT_CSV_PATH}"

############################################
# Status bar
############################################
STATUS_LINE_WIDTH=0

show_status_bar() {
  local queue_count=${#QUEUE[@]}
  local progress_count=${#JOB_PIDS[@]}
  local migrated_count=${#MIGRATED[@]}
  local failed_count=${#FAILED[@]}

  local status="QUEUE: ${queue_count} | IN PROGRESS: ${progress_count} | MIGRATED: ${migrated_count} | MIGRATION FAILED: ${failed_count}"
  (( ${#status} > STATUS_LINE_WIDTH )) && STATUS_LINE_WIDTH=${#status}
  printf "\r\033[36m%-${STATUS_LINE_WIDTH}s\033[0m" "${status}"
}

############################################
# Main loop
############################################
while (( ${#QUEUE[@]} > 0 )) || (( ${#JOB_PIDS[@]} > 0 )); do

  while (( ${#JOB_PIDS[@]} < MAX_CONCURRENT )) && (( ${#QUEUE[@]} > 0 )); do
    repo_info="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")

    IFS=',' read -r gitlab_group gitlab_project github_org github_repo gh_repo_visibility <<< "${repo_info}"

    safe_name="$(echo "${github_org}_${github_repo}" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-')"
    # log_file="$LOG_DIR/gl2gh-${safe_name}-${timestamp}.log"
    log_file="$REPO_LOG_DIR/gl2gh-${safe_name}-${timestamp}.log"

    update_repo_status_in_csv "${github_org}" "${github_repo}" "In Progress" "${log_file}"

    (
      if migrate_repository "${gitlab_group}" "${gitlab_project}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "${log_file}"; then
        echo "SUCCESS" > "${log_file}.result"
      else
        echo "FAILED" > "${log_file}.result"
      fi
    ) &

    pid=$!
    JOB_PIDS["$pid"]="${repo_info}"
    JOB_LOGS["$pid"]="${log_file}"
    JOB_ORGS["$pid"]="${github_org}"
    JOB_REPOS["$pid"]="${github_repo}"
    JOB_LASTLEN["$pid"]=0

    show_status_bar
  done

  for pid in "${!JOB_PIDS[@]}"; do
    log_file="${JOB_LOGS[$pid]}"
    last="${JOB_LASTLEN[$pid]}"

    if [[ -f "${log_file}" ]]; then
      new_len="$(wc -c < "${log_file}")"
      if (( new_len > last )); then
        delta_bytes=$(( new_len - last ))
        echo ""
        tail -c "${delta_bytes}" "${log_file}" | tr -d '\r' | while IFS= read -r l; do
          [[ -n "${l}" ]] && echo "${l}"
        done
        JOB_LASTLEN["$pid"]="${new_len}"
        show_status_bar
      fi
    fi
  done

  for pid in "${!JOB_PIDS[@]}"; do
    if ! ps -p "${pid}" > /dev/null 2>&1; then
      repo_info="${JOB_PIDS[$pid]}"
      log_file="${JOB_LOGS[$pid]}"
      github_org="${JOB_ORGS[$pid]}"
      github_repo="${JOB_REPOS[$pid]}"

      result="FAILED"
      if [[ -f "${log_file}.result" ]]; then
        result="$(<"${log_file}.result")"
        rm -f "${log_file}.result"
      fi

      if [[ "${result}" == "SUCCESS" ]]; then
        MIGRATED+=("${repo_info}")
        update_repo_status_in_csv "${github_org}" "${github_repo}" "Success" "${log_file}"
      else
        FAILED+=("${repo_info}")
        update_repo_status_in_csv "${github_org}" "${github_repo}" "Failure" "${log_file}"
      fi

      unset JOB_PIDS["$pid"] JOB_LOGS["$pid"] JOB_ORGS["$pid"] JOB_REPOS["$pid"] JOB_LASTLEN["$pid"]
      show_status_bar
    fi
  done

  sleep 2
done

echo
echo "[INFO] All migrations completed."

total_repos=$(( ${#MIGRATED[@]} + ${#FAILED[@]} + SKIPPED ))

echo "[SUMMARY] Total: ${total_repos} | Migrated: ${#MIGRATED[@]} | Failed: ${#FAILED[@]} | Skipped: ${SKIPPED}"
echo "[INFO] Wrote migration results with Migration_Status column: ${OUTPUT_CSV_PATH}"

############################################
# Generate repos_with_status.csv
############################################
echo "[INFO] Generating repos_with_status.csv for downstream stages..."

echo "gitlab_group,gitlab_project,github_org,github_repo,gh_repo_visibility,MigrationStatus" > "${REPOS_WITH_STATUS_CSV}"

for item in "${MIGRATED[@]}"; do
  IFS=',' read -r gitlab_group gitlab_project github_org github_repo visibility <<< "${item}"
  echo "${gitlab_group},${gitlab_project},${github_org},${github_repo},${visibility},Success" >> "${REPOS_WITH_STATUS_CSV}"
done

for item in "${FAILED[@]}"; do
  IFS=',' read -r gitlab_group gitlab_project github_org github_repo visibility <<< "${item}"
  echo "${gitlab_group},${gitlab_project},${github_org},${github_repo},${visibility},Failed" >> "${REPOS_WITH_STATUS_CSV}"
done

echo "[INFO] Generated ${REPOS_WITH_STATUS_CSV}"

############################################
# Move newly created Octoshift logs
############################################
while IFS= read -r logfile; do
  [[ -z "$logfile" ]] && continue

  if ! grep -Fxq "$logfile" <<< "$existing_octoshift_logs"; then
    mv "$PWD/$logfile" "$LOG_DIR/" 2>/dev/null || true
  fi
done < <(
  find "$PWD" -maxdepth 1 -type f \
    \( -name "*.octoshift.log" -o -name "*.octoshift.verbose.log" \) \
    -printf "%f\n" 2>/dev/null
)

############################################
# 3-way exit code
############################################

# Nothing was actually attempted
if (( ${#MIGRATED[@]} == 0 && ${#FAILED[@]} == 0 )); then
  echo "[ERROR] No repositories were migrated. All ${SKIPPED} repositories were skipped."
  exit 1

# All attempted migrations succeeded
elif (( ${#FAILED[@]} == 0 )); then
  echo "[SUCCESS] All ${#MIGRATED[@]} repositories migrated successfully"
  exit 0

# All attempted migrations failed
elif (( ${#MIGRATED[@]} == 0 )); then
  echo "[ERROR] All ${#FAILED[@]} repositories failed to migrate"

  for item in "${FAILED[@]}"; do
    IFS=',' read -r gitlab_group gitlab_project github_org github_repo visibility <<< "${item}"
    echo "[ERROR] Failed: ${github_org}/${github_repo} (${gitlab_group}/${gitlab_project})"
  done
  exit 1

# Partial success
else
  echo "[WARNING] Migration completed with partial success: ${#MIGRATED[@]} succeeded, ${#FAILED[@]} failed"

  for item in "${FAILED[@]}"; do
    IFS=',' read -r gitlab_group gitlab_project github_org github_repo visibility <<< "${item}"
    echo "[WARNING] Failed: ${github_org}/${github_repo} (${gitlab_group}/${gitlab_project})"
  done

  exit 0
fi
