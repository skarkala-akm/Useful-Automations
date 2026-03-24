#!/bin/bash
# teardown.sh
# Cleanly removes all intermediate-account IAM resources created for cross-account S3 access.
# Does NOT touch the customer account (you don't have access to it).
# All actions are audit logged.
#
# Usage: bash teardown.sh [--user IAM_USER_NAME] [--account ACCOUNT_ID] [--policy POLICY_NAME]
# Env vars: IAM_USER_NAME, INTERMEDIATE_ACCOUNT_ID, ASSUME_POLICY_NAME

set -e

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Audit logging ────────────────────────────────────────────────────────────
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$HOME/aws-iam-audit-logs}"
mkdir -p "$AUDIT_LOG_DIR"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-teardown.log"
exec > >(tee -a "$AUDIT_LOG") 2>&1

log_event() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] EVENT=$1 | OPERATOR=$(whoami) | $2" | tee -a "$AUDIT_LOG"
}

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         INTERMEDIATE ACCOUNT TEARDOWN — AUDIT LOG       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "START_TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "OPERATOR:   $(whoami)@$(hostname)"
echo "AUDIT_LOG:  $AUDIT_LOG"
echo ""

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --user)        IAM_USER_NAME="$2";     shift ;;
    --account)     INTERMEDIATE_ACCOUNT_ID="$2"; shift ;;
    --policy)      ASSUME_POLICY_NAME="$2"; shift ;;
    --aws-profile) export AWS_PROFILE="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# ─── Collect missing config ──────────────────────────────────────────────────
[ -z "$IAM_USER_NAME" ] && { echo -e "${YELLOW}IAM username to remove:${NC}"; read -r IAM_USER_NAME; }
[ -z "$ASSUME_POLICY_NAME" ] && { echo -e "${YELLOW}Assume-role policy name to remove:${NC}"; read -r ASSUME_POLICY_NAME; }

# ─── Verify account ───────────────────────────────────────────────────────────
echo -e "${BLUE}─── Account Verification ───────────────────────────────────${NC}"
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $CURRENT_ACCOUNT"

echo ""
echo -e "${RED}⚠️  WARNING: This will PERMANENTLY DELETE the following resources:${NC}"
echo "   - IAM user: $IAM_USER_NAME"
echo "   - All access keys for that user"
echo "   - IAM policy: $ASSUME_POLICY_NAME"
echo ""
echo -e "${RED}   This action cannot be undone.${NC}"
echo ""
echo -e "${YELLOW}   The customer account resources are NOT touched.${NC}"
echo -e "${YELLOW}   Notify the customer to remove their role after confirming no traffic.${NC}"
echo ""
read -p "Type 'DELETE' to confirm teardown: " CONFIRM
[ "$CONFIRM" = "DELETE" ] || { echo "Aborted — did not type DELETE."; log_event "TEARDOWN_ABORTED" "operator_declined"; exit 1; }

log_event "TEARDOWN_START" "account=$CURRENT_ACCOUNT user=$IAM_USER_NAME policy=$ASSUME_POLICY_NAME"

# ─── Step 1: Detach policies from user ───────────────────────────────────────
echo ""
echo -e "${BLUE}─── Step 1: Detach Policies from User ──────────────────────${NC}"
POLICY_ARN="arn:aws:iam::${CURRENT_ACCOUNT}:policy/${ASSUME_POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  aws iam detach-user-policy \
    --user-name "$IAM_USER_NAME" \
    --policy-arn "$POLICY_ARN" 2>/dev/null || echo "  (Policy not attached or already detached)"
  echo -e "${GREEN}  ✓ Policy detached: $POLICY_ARN${NC}"
  log_event "DETACHED_POLICY" "user=$IAM_USER_NAME policy=$POLICY_ARN"
else
  echo "  Policy not found: $POLICY_ARN (skipping)"
fi

# ─── Step 2: Delete all access keys ──────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Step 2: Delete Access Keys ─────────────────────────────${NC}"
KEY_IDS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" \
  --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")

if [ -z "$KEY_IDS" ]; then
  echo "  No access keys found."
else
  for KEY_ID in $KEY_IDS; do
    aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$KEY_ID"
    echo -e "${GREEN}  ✓ Deleted access key: $KEY_ID${NC}"
    log_event "DELETED_ACCESS_KEY" "user=$IAM_USER_NAME key_id=$KEY_ID"
  done
fi

# ─── Step 3: Delete IAM user ─────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Step 3: Delete IAM User ────────────────────────────────${NC}"
if aws iam get-user --user-name "$IAM_USER_NAME" &>/dev/null; then
  aws iam delete-user --user-name "$IAM_USER_NAME"
  echo -e "${GREEN}  ✓ IAM user deleted: $IAM_USER_NAME${NC}"
  log_event "DELETED_IAM_USER" "user=$IAM_USER_NAME"
else
  echo "  User not found: $IAM_USER_NAME (already deleted?)"
fi

# ─── Step 4: Delete IAM policy ───────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Step 4: Delete IAM Policy ──────────────────────────────${NC}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  aws iam delete-policy --policy-arn "$POLICY_ARN"
  echo -e "${GREEN}  ✓ IAM policy deleted: $POLICY_ARN${NC}"
  log_event "DELETED_IAM_POLICY" "policy=$POLICY_ARN"
else
  echo "  Policy not found: $POLICY_ARN (already deleted?)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
log_event "TEARDOWN_COMPLETE" "account=$CURRENT_ACCOUNT user=$IAM_USER_NAME policy=$ASSUME_POLICY_NAME"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  TEARDOWN COMPLETE                                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Removed: IAM user $IAM_USER_NAME"
echo "  Removed: IAM policy $ASSUME_POLICY_NAME"
echo "  Removed: All associated access keys"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Notify the customer to remove their IAM role ($ROLE_NAME)"
echo "     Use the change-request email template."
echo "  2. Confirm no application traffic is using the removed credentials."
echo ""
echo "Audit log: $AUDIT_LOG"
