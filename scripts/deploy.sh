#!/usr/bin/env bash
#
# deploy.sh - package, upload, and deploy the Temperature Monitor CloudFormation app.
#
# Settings without defaults are required command-line flags; optional settings
# are environment variables. Progress and diagnostics go to stderr; on success
# the stack's output values are printed to stdout. Run with --help for details.
#
# Written to be bash 3.2 compatible (stock macOS): no associative arrays,
# mapfile, or other bash 4+ features.

set -Eeuo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# <source directory / function name>:<zip base name used in the S3 key>
# The zip base names must match the S3Keys in nested/lambda.yml.
FUNCTION_SPECS="currentTemp:current_temp emailProcessor:email_processor sendEmail:send_email sendSMS:send_sms smsProcessor:sms_processor tempMonitor:temp_monitor heartbeatMonitor:heartbeat_monitor"

WORK_DIR=""

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT

is_true() {
  case "${1:-}" in true|TRUE|True|1|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<'EOF'
Usage: deploy.sh --templates-bucket BUCKET --lambda-bucket BUCKET \
                 --functions-dir DIR --layer-zip FILE \
                 --twilio-account-sid SID --twilio-auth-token TOKEN

Packages the Lambda functions, uploads the code and nested templates to S3,
deploys the CloudFormation stack, and prints the stack's output values.

Required (command line):
  --templates-bucket BUCKET   S3 bucket for the nested CloudFormation templates
  --lambda-bucket BUCKET      S3 bucket for the Lambda packages and Twilio layer
                              (must be in the same region as the stack)
  --functions-dir DIR         Directory with one subdirectory per function, each
                              containing lambda_function.rb: currentTemp,
                              emailProcessor, heartbeatMonitor, sendEmail,
                              sendSMS, smsProcessor, tempMonitor
  --layer-zip FILE            Twilio layer zip, built for the ruby3.4 runtime
  --twilio-account-sid SID    Twilio account SID
  --twilio-auth-token TOKEN   Twilio auth token
  -h, --help                  Show this help

Optional (environment variables):
  Deployment
    STACK_NAME                CloudFormation stack name  [temperature-monitor]
    TEMPLATES_PREFIX          S3 key prefix for templates [temperature-monitor]
    AWS_PROFILE, AWS_REGION   Standard AWS CLI credential/region selection

  App configuration. If unset, the default in main.yml applies (NOT the
  stack's previously deployed value, so re-export these on every update):
    DEVICE_ID                        -> DeviceId
    TWILIO_PHONE_NUMBER              -> TwilioPhoneNumber
    ALERT_TEMP_F                     -> AlertTempF
    MONITOR_SCHEDULE_EXPRESSION      -> MonitorScheduleExpression
    NOTIFICATIONS_SUBSCRIPTION_EMAIL -> NotificationsSubscriptionEmail
    INCOMING_EMAIL_RECIPIENT         -> IncomingEmailRecipient

  Behavior (set to "true" to enable; all default to false):
    PREVIEW_ONLY                Upload artifacts and create a change set, but
                                do not execute it
    ACTIVATE_SES_RULE_SET       After deploying, make this stack's SES receipt
                                rule set the active one. Only one rule set can
                                be active per region, so this REPLACES any
                                currently active rule set.
    DELETE_ROLLED_BACK_STACK    If a previous create failed and left the stack
                                in ROLLBACK_COMPLETE, delete it and start over
    SKIP_NAME_COLLISION_CHECK   Skip the check for pre-existing Lambda
                                functions with this app's names
EOF
}

# ---------------------------------------------------------------------------
# Arguments and configuration
# ---------------------------------------------------------------------------

templates_bucket=""
lambda_bucket=""
functions_dir=""
layer_zip=""
twilio_account_sid=""
twilio_auth_token=""

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value (see --help)"
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --*=*)     # split --flag=value into --flag value and re-process
                 set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
      --templates-bucket)   need_value "$@"; templates_bucket="$2"; shift 2 ;;
      --lambda-bucket)      need_value "$@"; lambda_bucket="$2"; shift 2 ;;
      --functions-dir)      need_value "$@"; functions_dir="$2"; shift 2 ;;
      --layer-zip)          need_value "$@"; layer_zip="$2"; shift 2 ;;
      --twilio-account-sid) need_value "$@"; twilio_account_sid="$2"; shift 2 ;;
      --twilio-auth-token)  need_value "$@"; twilio_auth_token="$2"; shift 2 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done

  local missing=()
  [[ -n "$templates_bucket" ]]   || missing+=(--templates-bucket)
  [[ -n "$lambda_bucket" ]]      || missing+=(--lambda-bucket)
  [[ -n "$functions_dir" ]]      || missing+=(--functions-dir)
  [[ -n "$layer_zip" ]]          || missing+=(--layer-zip)
  [[ -n "$twilio_account_sid" ]] || missing+=(--twilio-account-sid)
  [[ -n "$twilio_auth_token" ]]  || missing+=(--twilio-auth-token)
  if (( ${#missing[@]} )); then
    printf 'ERROR: missing required argument(s): %s\n\n' "${missing[*]}" >&2
    usage >&2
    exit 2
  fi
}

load_env() {
  STACK_NAME="${STACK_NAME:-temperature-monitor}"
  TEMPLATES_PREFIX="${TEMPLATES_PREFIX:-temperature-monitor}"
  TEMPLATES_PREFIX="${TEMPLATES_PREFIX#/}"
  TEMPLATES_PREFIX="${TEMPLATES_PREFIX%/}"
  PREVIEW_ONLY="${PREVIEW_ONLY:-false}"
  ACTIVATE_SES_RULE_SET="${ACTIVATE_SES_RULE_SET:-false}"
  DELETE_ROLLED_BACK_STACK="${DELETE_ROLLED_BACK_STACK:-false}"
  SKIP_NAME_COLLISION_CHECK="${SKIP_NAME_COLLISION_CHECK:-false}"

  local name_re='^[A-Za-z][A-Za-z0-9-]{0,127}$'
  [[ "$STACK_NAME" =~ $name_re ]] || die "invalid STACK_NAME '$STACK_NAME' (letters, digits, hyphens; must start with a letter)"
  [[ -n "$TEMPLATES_PREFIX" ]] || die "TEMPLATES_PREFIX must not be empty"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

sha256_file()  {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

check_local_inputs() {
  local tool pair fn bad=""
  for tool in aws zip; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "required tool not found: sha256sum or shasum"

  [[ -f "$SCRIPT_DIR/main.yml" ]] || die "main.yml not found next to deploy.sh"
  [[ -d "$SCRIPT_DIR/nested" ]]   || die "nested/ templates directory not found next to deploy.sh"

  [[ -d "$functions_dir" ]] || die "--functions-dir is not a directory: $functions_dir"
  functions_dir="$(cd "$functions_dir" && pwd)"
  for pair in $FUNCTION_SPECS; do
    fn="${pair%%:*}"
    [[ -f "$functions_dir/$fn/lambda_function.rb" ]] || bad="$bad $fn"
  done
  [[ -z "$bad" ]] || die "missing <function>/lambda_function.rb under $functions_dir for:$bad"

  [[ -f "$layer_zip" ]] || die "--layer-zip is not a file: $layer_zip"
  layer_zip="$(cd "$(dirname "$layer_zip")" && pwd)/$(basename "$layer_zip")"
  check_layer_zip
}

# The Twilio layer must be built for the ruby3.4 runtime. Lambda looks for
# gems under ruby/gems/<ruby version>/ in a layer; warn if that is absent.
check_layer_zip() {
  command -v unzip >/dev/null 2>&1 || return 0
  local listing
  listing="$(unzip -Z1 "$layer_zip" 2>/dev/null)" || die "--layer-zip is not a readable zip file: $layer_zip"
  if ! grep -q '^ruby/gems/3\.4\.0/' <<<"$listing"; then
    warn "$layer_zip has no ruby/gems/3.4.0/ directory - it may have been built for a different Ruby version"
    warn "sendSMS may fail at runtime if the layer's gems don't match ruby3.4"
  fi
}

resolve_aws_context() {
  local identity
  region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -z "$region" ]]; then region="$(aws configure get region 2>/dev/null || true)"; fi
  [[ -n "$region" ]] || die "no AWS region configured (set AWS_REGION or configure a default region)"
  export AWS_DEFAULT_REGION="$region" AWS_REGION="$region"

  identity="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)" \
    || die "unable to call AWS - check credentials: $identity"
  account_id="${identity%%$'\t'*}"
  caller_arn="${identity#*$'\t'}"
}

bucket_region() {
  local loc
  loc="$(aws s3api get-bucket-location --bucket "$1" --query LocationConstraint --output text 2>&1)" \
    || die "cannot access S3 bucket '$1': $loc"
  case "$loc" in
    None|null|"") echo us-east-1 ;;
    EU)           echo eu-west-1 ;;
    *)            echo "$loc" ;;
  esac
}

check_buckets() {
  local r
  r="$(bucket_region "$lambda_bucket")" || exit 1
  [[ "$r" == "$region" ]] \
    || die "--lambda-bucket '$lambda_bucket' is in $r but the stack deploys to $region; Lambda requires its code bucket in the same region"
  r="$(bucket_region "$templates_bucket")" || exit 1
  [[ "$r" == "$region" ]] \
    || warn "--templates-bucket '$templates_bucket' is in $r, not $region; nested stack template URLs may not resolve"
  return 0
}

validate_templates() {
  local f size
  log "Validating templates..."
  for f in "$SCRIPT_DIR/main.yml" "$SCRIPT_DIR"/nested/*.yml; do
    size="$(wc -c < "$f" | tr -d ' ')"
    if (( size > 51200 )); then
      warn "not validating $(basename "$f") ($size bytes exceeds the 51,200-byte inline limit)"
      continue
    fi
    aws cloudformation validate-template --template-body "file://$f" >/dev/null \
      || die "template validation failed: $f"
  done
}

inspect_stack() {
  stack_status="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  is_new_stack=false
  case "$stack_status" in
    ""|REVIEW_IN_PROGRESS)
      is_new_stack=true ;;
    ROLLBACK_COMPLETE)
      if is_true "$DELETE_ROLLED_BACK_STACK"; then
        log "Stack '$STACK_NAME' is in ROLLBACK_COMPLETE (a failed first create); deleting it..."
        aws cloudformation delete-stack --stack-name "$STACK_NAME"
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
        stack_status=""
        is_new_stack=true
      else
        die "stack '$STACK_NAME' is in ROLLBACK_COMPLETE (a previous create failed) and cannot be updated. Delete it with 'aws cloudformation delete-stack --stack-name $STACK_NAME' or re-run with DELETE_ROLLED_BACK_STACK=true"
      fi ;;
    *_IN_PROGRESS)
      die "stack '$STACK_NAME' has an operation in progress ($stack_status); wait for it to finish" ;;
    *_FAILED)
      die "stack '$STACK_NAME' is in $stack_status and needs manual attention before it can be deployed" ;;
    *) ;;
  esac
}

# Several resources have fixed names (Lambda functions, DynamoDB tables, the SNS
# topic), so a first deploy into an account/region that already runs this app
# fails partway through and rolls back. Catch the common case up front.
check_name_collisions() {
  local pair fn found=""
  for pair in $FUNCTION_SPECS; do
    fn="${pair%%:*}"
    if aws lambda get-function --function-name "$fn" >/dev/null 2>&1; then found="$found $fn"; fi
  done
  if [[ -n "$found" ]]; then
    die "Lambda function(s) already exist in $region outside this stack:$found
       This stack uses fixed names for its functions, DynamoDB tables, and SNS topic, so creating it here would fail.
       Deploy to a different region/account, remove the existing resources first, or set SKIP_NAME_COLLISION_CHECK=true."
  fi
}

# ---------------------------------------------------------------------------
# Packaging and upload
# ---------------------------------------------------------------------------

# One version label for all code, derived from file contents (not zip bytes,
# which vary run to run). CloudFormation only redeploys function code or
# publishes a new layer version when the S3 keys in the template change, so
# the label goes into every key via the CodeVersion parameter.
compute_code_version() {
  local pair fn dir f
  {
    for pair in $FUNCTION_SPECS; do
      fn="${pair%%:*}"
      dir="$functions_dir/$fn"
      find "$dir" -type f ! -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(sha256_file "$f")" "$fn/${f#"$dir"/}"
      done
    done
    printf '%s  twilio-layer\n' "$(sha256_file "$layer_zip")"
  } | sha256_stdin | cut -c1-12
}

upload_if_missing() {
  local file="$1" key="$2"
  if aws s3api head-object --bucket "$lambda_bucket" --key "$key" >/dev/null 2>&1; then
    log "  already uploaded: $key"
  else
    aws s3 cp --only-show-errors "$file" "s3://$lambda_bucket/$key" >&2
    log "  uploaded: $key"
  fi
}

package_and_upload_code() {
  local pair fn zip_base stage zip_path
  log "Packaging and uploading Lambda code (version $code_version)..."
  for pair in $FUNCTION_SPECS; do
    fn="${pair%%:*}"
    zip_base="${pair##*:}"
    stage="$WORK_DIR/stage/$fn"
    zip_path="$WORK_DIR/$zip_base.zip"
    mkdir -p "$stage"
    cp -R "$functions_dir/$fn/." "$stage/"
    # Lambda runs as a different user and needs world-readable files.
    chmod -R a+rX "$stage"
    (cd "$stage" && zip -q -r -X "$zip_path" . -x '*.DS_Store')
    upload_if_missing "$zip_path" "functions/$code_version/$zip_base.zip"
  done
  upload_if_missing "$layer_zip" "layers/$code_version/twilio.zip"
}

upload_templates() {
  log "Uploading nested templates to s3://$templates_bucket/$TEMPLATES_PREFIX/nested/ ..."
  aws s3 cp --only-show-errors --recursive --exclude '*' --include '*.yml' \
    "$SCRIPT_DIR/nested/" "s3://$templates_bucket/$TEMPLATES_PREFIX/nested/" >&2
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

PARAMS=()
PARAMS_SHOWN=()

add_param() {   # name value [secret]
  PARAMS+=("$1=$2")
  if [[ "${3:-}" == secret ]]; then PARAMS_SHOWN+=("$1=********"); else PARAMS_SHOWN+=("$1=$2"); fi
}
add_optional_param() {   # name value - only passed when the value is non-empty
  if [[ -n "$2" ]]; then add_param "$1" "$2"; fi
  return 0
}

build_parameters() {
  add_param TemplatesBucket  "$templates_bucket"
  add_param TemplatesPrefix  "$TEMPLATES_PREFIX"
  add_param LambdaCodeBucket "$lambda_bucket"
  add_param CodeVersion      "$code_version"
  add_param TwilioAccountSid "$twilio_account_sid" secret
  add_param TwilioAuthToken  "$twilio_auth_token" secret
  add_optional_param DeviceId                       "${DEVICE_ID:-}"
  add_optional_param TwilioPhoneNumber              "${TWILIO_PHONE_NUMBER:-}"
  add_optional_param AlertTempF                     "${ALERT_TEMP_F:-}"
  add_optional_param MonitorScheduleExpression      "${MONITOR_SCHEDULE_EXPRESSION:-}"
  add_optional_param NotificationsSubscriptionEmail "${NOTIFICATIONS_SUBSCRIPTION_EMAIL:-}"
  add_optional_param IncomingEmailRecipient         "${INCOMING_EMAIL_RECIPIENT:-}"
}

# Nested stacks hide the real error behind "embedded stack failed", so show the
# failed events of the root stack and of every nested stack.
print_failures() {
  local q="StackEvents[?contains(ResourceStatus, 'FAILED')].[LogicalResourceId, ResourceStatus, ResourceStatusReason]"
  local nested id
  warn "failed events for stack '$STACK_NAME':"
  aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --query "$q" --output text >&2 || true
  nested="$(aws cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query "StackEvents[?ResourceType=='AWS::CloudFormation::Stack' && LogicalResourceId!='$STACK_NAME'].PhysicalResourceId" \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"
  for id in $nested; do
    [[ -n "$id" && "$id" != None ]] || continue
    warn "failed events for nested stack $id:"
    aws cloudformation describe-stack-events --stack-name "$id" --query "$q" --output text >&2 || true
  done
}

run_deploy() {
  local args=(cloudformation deploy
    --stack-name "$STACK_NAME"
    --template-file "$SCRIPT_DIR/main.yml"
    --capabilities CAPABILITY_NAMED_IAM
    --no-fail-on-empty-changeset)
  if is_true "$PREVIEW_ONLY"; then args+=(--no-execute-changeset); fi
  # --parameter-overrides takes a variable-length list, so it goes last.
  args+=(--parameter-overrides "${PARAMS[@]}")

  if [[ "$is_new_stack" == true ]]; then log "Creating stack '$STACK_NAME'..."; else log "Updating stack '$STACK_NAME'..."; fi
  if ! aws "${args[@]}" >&2; then
    print_failures
    die "deployment of stack '$STACK_NAME' failed"
  fi
}

# ---------------------------------------------------------------------------
# After deployment
# ---------------------------------------------------------------------------

fetch_outputs() {
  stack_outputs="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text)"
  if [[ "$stack_outputs" == None ]]; then stack_outputs=""; fi
}

output_value() {
  printf '%s\n' "$stack_outputs" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'
}

print_outputs() {
  printf '%s\n' "$stack_outputs" | awk -F'\t' '
    { k[NR] = $1; v[NR] = $2; if (length($1) > w) w = length($1) }
    END { fmt = "%-" w "s  %s\n"; for (i = 1; i <= NR; i++) printf fmt, k[i], v[i] }'
}

activate_ses_rule_set() {
  local name current
  name="$(output_value IncomingEmailRuleSetName)"
  [[ -n "$name" ]] || die "stack has no IncomingEmailRuleSetName output; cannot activate the SES rule set"
  current="$(aws ses describe-active-receipt-rule-set --query 'Metadata.Name' --output text 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != None && "$current" != "$name" ]]; then
    warn "replacing the active SES receipt rule set '$current' with '$name' (only one can be active per region)"
  fi
  log "Activating SES receipt rule set '$name'..."
  aws ses set-active-receipt-rule-set --rule-set-name "$name" >&2
}

print_next_steps() {
  local rule_set
  rule_set="$(output_value IncomingEmailRuleSetName)"
  {
    echo
    echo "Remaining manual steps:"
    echo "  - Confirm the SNS email subscription (AWS emails a confirmation link to the notifications address)."
    echo "  - Point the sensor at TemperatureApiEndpoint and Twilio's incoming-message webhook at SMSApiEndpoint."
    if ! is_true "$ACTIVATE_SES_RULE_SET"; then
      echo "  - SES: verify the receiving domain/address, then activate the rule set:"
      echo "      aws ses set-active-receipt-rule-set --rule-set-name ${rule_set:-<IncomingEmailRuleSetName>}"
      echo "    (or re-run with ACTIVATE_SES_RULE_SET=true; this replaces any currently active rule set)"
    else
      echo "  - SES: verify the receiving domain/address (the rule set itself is active)."
    fi
    echo
  } >&2
}

# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  load_env
  check_local_inputs
  resolve_aws_context

  log "Stack:   $STACK_NAME"
  log "Account: $account_id ($caller_arn)"
  log "Region:  $region"

  check_buckets
  validate_templates
  inspect_stack
  if [[ "$is_new_stack" == true ]] && ! is_true "$SKIP_NAME_COLLISION_CHECK"; then
    check_name_collisions
  fi

  WORK_DIR="$(mktemp -d)"
  code_version="$(compute_code_version)"
  package_and_upload_code
  upload_templates

  build_parameters
  log "Parameter overrides:"
  printf '      %s\n' "${PARAMS_SHOWN[@]}" >&2
  run_deploy

  if is_true "$PREVIEW_ONLY"; then
    log "PREVIEW_ONLY: change set created but not executed. Review and execute it in the CloudFormation console, or re-run without PREVIEW_ONLY."
    return 0
  fi

  fetch_outputs
  if is_true "$ACTIVATE_SES_RULE_SET"; then activate_ses_rule_set; fi
  log "Deployment complete."
  print_next_steps
  log "Stack outputs:"
  print_outputs
}

main "$@"
