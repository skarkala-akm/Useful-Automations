#!/bin/bash
# rotate-credentials.sh
# Rotates IAM access keys for the intermediate account IAM user.
# Safely creates the new key, verifies it works, then deactivates and deletes the old key.
# All actions are audit logged.
#
# Usage: bash rotate-credentials.sh [--user IAM_USER_NAME] [--account ACCOUNT_ID]
# Env vars: IAM_USER_NAME, INTERMEDIATE_ACCOUNT_ID, ROLE_ARN, EXTERNAL_ID

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
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-credential-rotation.log"
exec > >(tee -a "$AUDIT_LOG") 2>&1

log_event() {
  local EVENT="$1"
  local DETAIL="$2"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] EVENT=$EVENT | OPERATOR=$(whoami) | $DETAIL" | tee -a "$AUDIT_LOG"
}

# ─── Parse args / env ────────────────────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --user)        IAM_USER_NAME="$2";    shift ;;
    --account)     INTERMEDIATE_ACCOUNT_ID="$2"; shift ;;
    --aws-profile) export AWS_PROFILE="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

echo "╔══════════════════════════════════════════════════════════╗"
echo "║        IAM CREDENTIAL ROTATION — AUDIT LOG              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "START_TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "OPERATOR:   $(whoami)@$(hostname)"
echo "AUDIT_LOG:  $AUDIT_LOG"
echo ""

# ─── Collect missing config ──────────────────────────────────────────────────
if [ -z "$IAM_USER_NAME" ]; then
  echo -e "${YELLOW}IAM username to rotate credentials for:${NC}"
  read -r IAM_USER_NAME
fi

if [ -z "$ROLE_ARN" ]; then
  echo -e "${YELLOW}Role ARN in customer account (for verification test):${NC}"
  read -r ROLE_ARN
fi

if [ -z "$EXTERNAL_ID" ]; then
  echo -e "${YELLOW}External ID (for verification test):${NC}"
  read -rs EXTERNAL_ID
  echo ""
fi

# ─── Verify account ───────────────────────────────────────────────────────────
echo -e "${BLUE}─── Account Verification ───────────────────────────────────${NC}"
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
CURRENT_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Account: $CURRENT_ACCOUNT"
echo "Caller:  $CURRENT_ARN"
log_event "ROTATION_START" "account=$CURRENT_ACCOUNT user=$IAM_USER_NAME"

echo ""
echo -e "${YELLOW}⚠️  This will rotate credentials for IAM user: $IAM_USER_NAME${NC}"
echo -e "${YELLOW}   in AWS account: $CURRENT_ACCOUNT${NC}"
echo ""
read -p "Confirm rotation. Continue? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; log_event "ROTATION_ABORTED" "operator_declined"; exit 1; }

# ─── Check existing keys ──────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Current Access Keys ────────────────────────────────────${NC}"
EXISTING_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" \
  --query 'AccessKeyMetadata[*].[AccessKeyId,Status,CreateDate]' --output text)
echo "$EXISTING_KEYS"

KEY_COUNT=$(echo "$EXISTING_KEYS" | grep -c "AKIA" || true)
if [ "$KEY_COUNT" -ge 2 ]; then
  echo -e "${RED}ERROR: User already has 2 access keys. Delete one before rotating.${NC}"
  echo "Keys:"
  echo "$EXISTING_KEYS"
  log_event "ROTATION_FAILED" "reason=max_keys_reached count=$KEY_COUNT"
  exit 1
fi

OLD_KEY_ID=$(echo "$EXISTING_KEYS" | awk '{print $1}' | head -1)
echo ""
echo "Current key to replace: $OLD_KEY_ID"

# ─── Create new key ───────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Creating New Access Key ────────────────────────────────${NC}"
NEW_KEY_JSON=$(aws iam create-access-key --user-name "$IAM_USER_NAME")
NEW_KEY_ID=$(echo "$NEW_KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
NEW_SECRET=$(echo "$NEW_KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

echo -e "${GREEN}✓ New key created: $NEW_KEY_ID${NC}"
log_event "CREATED_ACCESS_KEY" "user=$IAM_USER_NAME new_key_id=$NEW_KEY_ID"

# Save new credentials to a temp file (chmod 600)
NEW_CREDS_FILE="$HOME/aws-iam-audit-logs/${TIMESTAMP}-new-credentials.json"
echo "$NEW_KEY_JSON" > "$NEW_CREDS_FILE"
chmod 600 "$NEW_CREDS_FILE"
echo "New credentials saved to: $NEW_CREDS_FILE (chmod 600)"
echo -e "${RED}⚠️  Store these credentials in your secrets manager before deleting this file.${NC}"

echo ""
echo -e "${YELLOW}New credentials:${NC}"
echo "  AWS_ACCESS_KEY_ID:     $NEW_KEY_ID"
echo "  AWS_SECRET_ACCESS_KEY: $NEW_SECRET"
echo ""
echo -e "${YELLOW}Update your application's environment with these values, then press Enter to verify.${NC}"
read -p "Press Enter when application is updated with new credentials..."

# ─── Verify new key works ─────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Verifying New Key ──────────────────────────────────────${NC}"
VERIFY_RESULT=$(AWS_ACCESS_KEY_ID="$NEW_KEY_ID" AWS_SECRET_ACCESS_KEY="$NEW_SECRET" \
  aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name rotation-verify-$(date +%s) \
  --external-id "$EXTERNAL_ID" \
  --query 'Credentials.AccessKeyId' --output text 2>&1)

if echo "$VERIFY_RESULT" | grep -q "ASIA"; then
  echo -e "${GREEN}✓ New credentials successfully assumed role.${NC}"
  log_event "ROTATION_VERIFIED" "new_key_id=$NEW_KEY_ID role_arn=$ROLE_ARN"
else
  echo -e "${RED}❌ Verification FAILED. New key cannot assume role.${NC}"
  echo "Error: $VERIFY_RESULT"
  echo ""
  echo -e "${YELLOW}The old key has NOT been deactivated. Please investigate.${NC}"
  log_event "ROTATION_VERIFY_FAILED" "new_key_id=$NEW_KEY_ID error=$VERIFY_RESULT"
  exit 1
fi

# ─── Deactivate old key ───────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Deactivating Old Key ───────────────────────────────────${NC}"
aws iam update-access-key \
  --user-name "$IAM_USER_NAME" \
  --access-key-id "$OLD_KEY_ID" \
  --status Inactive
echo -e "${GREEN}✓ Old key $OLD_KEY_ID deactivated.${NC}"
log_event "DEACTIVATED_ACCESS_KEY" "user=$IAM_USER_NAME old_key_id=$OLD_KEY_ID"

echo ""
read -p "Confirm old key is no longer in use, then press Enter to delete it..."

# ─── Delete old key ───────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Deleting Old Key ───────────────────────────────────────${NC}"
aws iam delete-access-key \
  --user-name "$IAM_USER_NAME" \
  --access-key-id "$OLD_KEY_ID"
echo -e "${GREEN}✓ Old key $OLD_KEY_ID deleted.${NC}"
log_event "DELETED_ACCESS_KEY" "user=$IAM_USER_NAME old_key_id=$OLD_KEY_ID"
log_event "ROTATED_CREDENTIALS" "user=$IAM_USER_NAME old_key=$OLD_KEY_ID new_key=$NEW_KEY_ID"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  CREDENTIAL ROTATION COMPLETE                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Old key (deleted):  $OLD_KEY_ID"
echo "  New key (active):   $NEW_KEY_ID"
echo "  Credentials file:   $NEW_CREDS_FILE"
echo "  Audit log:          $AUDIT_LOG"
echo ""
echo -e "${YELLOW}Next rotation due: $(date -d '+90 days' +%Y-%m-%d 2>/dev/null || date -v +90d +%Y-%m-%d)${NC}"
echo ""
echo -e "${RED}⚠️  Move credentials from $NEW_CREDS_FILE to your secrets manager and delete the file.${NC}"
