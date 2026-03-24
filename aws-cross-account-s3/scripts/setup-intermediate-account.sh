#!/bin/bash
# setup-intermediate-account.sh
#
# Sets up the IAM user and access keys in the intermediate (broker) account.
# Generates a structured External ID. Does NOT create the AssumeRole policy —
# that is done separately in update-assume-role-policy.sh once the customer
# sends back their actual Role ARN.
#
# AWS AUTHENTICATION — set one of these before running:
#   export AWS_PROFILE=intermediate          # named profile (recommended)
#   export AWS_ACCESS_KEY_ID=... + AWS_SECRET_ACCESS_KEY=...  # env vars
#   export AWS_PROFILE=... (SSO profile after: aws sso login --profile ...)
#
# Usage:
#   bash setup-intermediate-account.sh \
#     --account-id      252685663126 \
#     --customer-id     613602870030 \
#     --access-mode     write \
#     [--user-name      s3-forwarder-user] \
#     [--policy-name    AllowAssumeCustomerS3Role] \
#     [--region         us-east-1] \
#     [--aws-profile    intermediate]
#
# All flags in [] are optional — safe defaults are used if omitted.
# Name conflicts are detected and alternatives are suggested before any change.

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Audit logging ────────────────────────────────────────────────────────────
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$HOME/aws-iam-audit-logs}"
mkdir -p "$AUDIT_LOG_DIR"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-setup-intermediate.log"
exec > >(tee -a "$AUDIT_LOG") 2>&1

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] EVENT=$1 | OPERATOR=$(whoami) | $2" | tee -a "$AUDIT_LOG"
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
DEFAULT_USER_NAME="s3-forwarder-user"
DEFAULT_POLICY_NAME="AllowAssumeCustomerS3Role"
DEFAULT_REGION="us-east-1"

# ─── Parse arguments ─────────────────────────────────────────────────────────
ACCOUNT_ID=""
CUSTOMER_ID=""
ACCESS_MODE=""
USER_NAME=""
POLICY_NAME=""
REGION=""
AWS_PROFILE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-id)    ACCOUNT_ID="$2";      shift 2 ;;
    --customer-id)   CUSTOMER_ID="$2";     shift 2 ;;
    --access-mode)   ACCESS_MODE="$2";     shift 2 ;;
    --user-name)     USER_NAME="$2";       shift 2 ;;
    --policy-name)   POLICY_NAME="$2";     shift 2 ;;
    --region)        REGION="$2";          shift 2 ;;
    --aws-profile)   AWS_PROFILE_ARG="$2"; shift 2 ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
  esac
done

# Apply AWS profile if provided (overrides existing AWS_PROFILE env var)
[ -n "$AWS_PROFILE_ARG" ] && export AWS_PROFILE="$AWS_PROFILE_ARG"

# ─── Validate required args ───────────────────────────────────────────────────
ERRORS=0
for var in ACCOUNT_ID CUSTOMER_ID ACCESS_MODE; do
  if [ -z "${!var}" ]; then
    echo -e "${RED}Missing required argument: --$(echo $var | tr '[:upper:]' '[:lower:]' | tr '_' '-')${NC}"
    ERRORS=$((ERRORS+1))
  fi
done
[ $ERRORS -gt 0 ] && exit 1

if [[ "$ACCESS_MODE" != "read" && "$ACCESS_MODE" != "write" && "$ACCESS_MODE" != "readwrite" ]]; then
  echo -e "${RED}--access-mode must be: read, write, or readwrite${NC}"
  exit 1
fi

# ─── Apply defaults ───────────────────────────────────────────────────────────
[ -z "$USER_NAME"   ] && USER_NAME="$DEFAULT_USER_NAME"
[ -z "$POLICY_NAME" ] && POLICY_NAME="$DEFAULT_POLICY_NAME"
[ -z "$REGION"      ] && REGION="$DEFAULT_REGION"

# ─── Banner ──────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      INTERMEDIATE ACCOUNT SETUP — AUDIT LOG             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  START_TIME:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  OPERATOR:      $(whoami)@$(hostname)"
echo "  AUDIT_LOG:     $AUDIT_LOG"
echo ""

# ─── Account verification ─────────────────────────────────────────────────────
echo -e "${BLUE}── Account verification ─────────────────────────────────────${NC}"
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1)
if [ $? -ne 0 ]; then
  echo -e "${RED}Cannot connect to AWS. Check credentials.${NC}"
  exit 1
fi

if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
  echo -e "${YELLOW}⚠  Warning: current account ($CURRENT_ACCOUNT) does not match --account-id ($ACCOUNT_ID).${NC}"
  read -p "   Continue anyway? (yes/no): " CONT
  [ "$CONT" = "yes" ] || { echo "Aborted."; exit 1; }
  ACCOUNT_ID="$CURRENT_ACCOUNT"
fi

CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo -e "${GREEN}  ✓ Connected: $ACCOUNT_ID ($CALLER_ARN)${NC}"
echo ""

# ─── Name conflict detection and resolution ───────────────────────────────────
echo -e "${BLUE}── Checking for naming conflicts ───────────────────────────${NC}"

# Helper: find a free name by appending -2, -3, ... until one is available
find_free_name() {
  local check_type="$1"   # "user" or "policy"
  local base_name="$2"
  local candidate="$base_name"
  local suffix=2
  while true; do
    if [ "$check_type" = "user" ]; then
      aws iam get-user --user-name "$candidate" &>/dev/null || break
    else
      local arn="arn:aws:iam::${ACCOUNT_ID}:policy/${candidate}"
      aws iam get-policy --policy-arn "$arn" &>/dev/null || break
    fi
    candidate="${base_name}-${suffix}"
    suffix=$((suffix+1))
  done
  echo "$candidate"
}

# Check IAM user
if aws iam get-user --user-name "$USER_NAME" &>/dev/null; then
  SUGGESTED=$(find_free_name "user" "$USER_NAME")
  echo -e "${YELLOW}  IAM user '$USER_NAME' already exists.${NC}"
  echo -e "  Suggested alternative: ${CYAN}$SUGGESTED${NC}"
  read -p "  Use '$SUGGESTED'? Or enter a custom name (leave blank to abort): " CHOICE
  if [ -z "$CHOICE" ]; then
    echo "Aborted."; exit 1
  elif [ "$CHOICE" = "y" ] || [ "$CHOICE" = "yes" ]; then
    USER_NAME="$SUGGESTED"
  else
    USER_NAME="$CHOICE"
    # Validate the custom name isn't taken either
    if aws iam get-user --user-name "$USER_NAME" &>/dev/null; then
      echo -e "${RED}  '$USER_NAME' also already exists. Aborting.${NC}"; exit 1
    fi
  fi
else
  echo -e "${GREEN}  ✓ IAM user name available: $USER_NAME${NC}"
fi

# Check policy name
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  SUGGESTED_P=$(find_free_name "policy" "$POLICY_NAME")
  echo -e "${YELLOW}  Policy '$POLICY_NAME' already exists.${NC}"
  echo -e "  Suggested alternative: ${CYAN}$SUGGESTED_P${NC}"
  read -p "  Use '$SUGGESTED_P'? Or enter a custom name (leave blank to abort): " CHOICEP
  if [ -z "$CHOICEP" ]; then
    echo "Aborted."; exit 1
  elif [ "$CHOICEP" = "y" ] || [ "$CHOICEP" = "yes" ]; then
    POLICY_NAME="$SUGGESTED_P"
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
  else
    POLICY_NAME="$CHOICEP"
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
    if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
      echo -e "${RED}  '$POLICY_NAME' also already exists. Aborting.${NC}"; exit 1
    fi
  fi
else
  echo -e "${GREEN}  ✓ Policy name available: $POLICY_NAME${NC}"
fi
echo ""

# ─── Confirm before making changes ────────────────────────────────────────────
echo -e "${BLUE}── Configuration summary ───────────────────────────────────${NC}"
echo "  Intermediate account:  $ACCOUNT_ID"
echo "  Customer account:      $CUSTOMER_ID"
echo "  IAM user name:         $USER_NAME"
echo "  Policy name:           $POLICY_NAME  (created in Step 4, not now)"
echo "  Access mode:           $ACCESS_MODE"
echo "  Region:                $REGION"
echo ""
read -p "Proceed with this configuration? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; log "SETUP_ABORTED" "operator_declined"; exit 1; }
echo ""

log "SETUP_START" "account=$ACCOUNT_ID user=$USER_NAME policy=$POLICY_NAME"

# ─── Step 1: Create IAM user ──────────────────────────────────────────────────
echo -e "${BLUE}── Step 1: Creating IAM user ────────────────────────────────${NC}"
aws iam create-user --user-name "$USER_NAME"
PRINCIPAL_ARN=$(aws iam get-user --user-name "$USER_NAME" --query 'User.Arn' --output text)
echo -e "${GREEN}  ✓ IAM user created${NC}"
echo "  Principal ARN: $PRINCIPAL_ARN"
log "CREATED_IAM_USER" "user=$USER_NAME arn=$PRINCIPAL_ARN"
echo ""

# ─── Step 2: Generate External ID ────────────────────────────────────────────
echo -e "${BLUE}── Step 2: Generating External ID ──────────────────────────${NC}"
# Format: akamai-<customer-slug>-<uuid>
# Customer slug: last segment of account ID, or a short hash
CUSTOMER_SLUG="acct$(echo $CUSTOMER_ID | tail -c 5)"
UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null || \
       cat /proc/sys/kernel/random/uuid 2>/dev/null || \
       openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')
EXTERNAL_ID="akamai-${CUSTOMER_SLUG}-${UUID}"
echo -e "${GREEN}  ✓ External ID: $EXTERNAL_ID${NC}"
echo -e "  ${YELLOW}⚠  Share via secure channel only — never plain email${NC}"
log "GENERATED_EXTERNAL_ID" "format=akamai-slug-uuid customer=$CUSTOMER_ID"
echo ""

# ─── Step 3: Create access keys ───────────────────────────────────────────────
echo -e "${BLUE}── Step 3: Creating access keys ─────────────────────────────${NC}"
CREDS_FILE="$AUDIT_LOG_DIR/${TIMESTAMP}-credentials-${USER_NAME}.json"
aws iam create-access-key --user-name "$USER_NAME" > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
ACCESS_KEY_ID=$(python3 -c "import json,sys; print(json.load(open('$CREDS_FILE'))['AccessKey']['AccessKeyId'])")
echo -e "${GREEN}  ✓ Access keys created and saved to:${NC}"
echo "  $CREDS_FILE  (chmod 600)"
echo -e "  ${RED}⚠  Move these to your secrets manager — never leave on disk long-term${NC}"
log "CREATED_ACCESS_KEY" "user=$USER_NAME key_id=$ACCESS_KEY_ID file=$CREDS_FILE"
echo ""

# ─── Step 4: Tag the user for traceability ───────────────────────────────────
echo -e "${BLUE}── Step 4: Tagging IAM user ─────────────────────────────────${NC}"
aws iam tag-user --user-name "$USER_NAME" --tags \
  "Key=Purpose,Value=cross-account-s3-${ACCESS_MODE}" \
  "Key=CustomerAccount,Value=$CUSTOMER_ID" \
  "Key=CreatedBy,Value=$(whoami)" \
  "Key=CreatedAt,Value=$TIMESTAMP" \
  "Key=S3Prefix,Value=$(echo $PREFIX | tr '/' '_')"
echo -e "${GREEN}  ✓ Tags applied${NC}"
log "TAGGED_IAM_USER" "user=$USER_NAME customer=$CUSTOMER_ID mode=$ACCESS_MODE"
echo ""

# ─── Summary & next steps ─────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  INTERMEDIATE ACCOUNT SETUP COMPLETE                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo -e "${CYAN}Values to share with the customer (via email):${NC}"
echo ""
echo "  Principal ARN:  $PRINCIPAL_ARN"
echo "  Access mode:    $ACCESS_MODE"
echo "  Region:         $REGION"
echo "  (S3 prefix: collect from your team before drafting the customer email)"
echo ""
echo -e "${CYAN}Values to send via SECURE CHANNEL only:${NC}"
echo ""
echo "  External ID:    $EXTERNAL_ID"
echo ""
echo -e "${CYAN}Values to store in your secrets manager:${NC}"
echo ""
echo "  Credentials file:  $CREDS_FILE"
echo "  Access Key ID:     $ACCESS_KEY_ID"
echo ""
echo -e "${YELLOW}Next step:${NC} Email the customer (use references/email-templates.md → initial-setup-request)"
echo -e "${YELLOW}After customer replies:${NC} Run scripts/update-assume-role-policy.sh with their Role ARN"
echo ""
echo "Audit log: $AUDIT_LOG"
log "SETUP_COMPLETE" "user=$USER_NAME arn=$PRINCIPAL_ARN key_id=$ACCESS_KEY_ID"
