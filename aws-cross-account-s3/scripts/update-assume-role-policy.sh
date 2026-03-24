#!/bin/bash
# update-assume-role-policy.sh
#
# Creates (or updates) the AssumeRole policy in the intermediate account,
# scoped to the exact Role ARN the customer provided. Run this after receiving
# the customer's reply email with their Role ARN.
#
# AWS AUTHENTICATION — set one of these before running:
#   export AWS_PROFILE=intermediate
#   export AWS_ACCESS_KEY_ID=... + AWS_SECRET_ACCESS_KEY=...
#
# Usage:
#   bash update-assume-role-policy.sh \
#     --role-arn        arn:aws:iam::613602870030:role/AcmeCorpLogDeliveryRole \
#     --user-name       s3-forwarder-user \
#     --account-id      252685663126 \
#     [--policy-name    AllowAssumeCustomerS3Role] \
#     [--aws-profile    intermediate]

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Audit logging ────────────────────────────────────────────────────────────
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$HOME/aws-iam-audit-logs}"
mkdir -p "$AUDIT_LOG_DIR"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-update-policy.log"
exec > >(tee -a "$AUDIT_LOG") 2>&1

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] EVENT=$1 | OPERATOR=$(whoami) | $2" | tee -a "$AUDIT_LOG"
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
ROLE_ARN=""
USER_NAME=""
ACCOUNT_ID=""
POLICY_NAME="AllowAssumeCustomerS3Role"
AWS_PROFILE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role-arn)    ROLE_ARN="$2";        shift 2 ;;
    --user-name)   USER_NAME="$2";       shift 2 ;;
    --account-id)  ACCOUNT_ID="$2";      shift 2 ;;
    --policy-name) POLICY_NAME="$2";     shift 2 ;;
    --aws-profile) AWS_PROFILE_ARG="$2"; shift 2 ;;
    *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
  esac
done

[ -n "$AWS_PROFILE_ARG" ] && export AWS_PROFILE="$AWS_PROFILE_ARG"

for var in ROLE_ARN USER_NAME ACCOUNT_ID; do
  if [ -z "${!var}" ]; then
    echo -e "${RED}Missing: --$(echo $var | tr '[:upper:]' '[:lower:]' | tr '_' '-')${NC}"
    exit 1
  fi
done

# ─── Validate Role ARN format ────────────────────────────────────────────────
if ! echo "$ROLE_ARN" | grep -qE '^arn:aws:iam::[0-9]{12}:role/.+$'; then
  echo -e "${RED}Invalid Role ARN format: $ROLE_ARN${NC}"
  echo "  Expected: arn:aws:iam::<12-digit-account-id>:role/<role-name>"
  exit 1
fi

CUSTOMER_ACCOUNT=$(echo "$ROLE_ARN" | cut -d: -f5)
ROLE_NAME=$(echo "$ROLE_ARN" | cut -d/ -f2-)

echo "╔══════════════════════════════════════════════════════════╗"
echo "║      UPDATE ASSUMEROLE POLICY — AUDIT LOG               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  START_TIME:       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  OPERATOR:         $(whoami)@$(hostname)"
echo "  AUDIT_LOG:        $AUDIT_LOG"
echo ""

# ─── Account verification ─────────────────────────────────────────────────────
echo -e "${BLUE}── Account verification ─────────────────────────────────────${NC}"
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
  echo -e "${YELLOW}⚠  Warning: current account ($CURRENT_ACCOUNT) ≠ --account-id ($ACCOUNT_ID)${NC}"
  read -p "   Continue? (yes/no): " CONT; [ "$CONT" = "yes" ] || exit 1
  ACCOUNT_ID="$CURRENT_ACCOUNT"
fi
echo -e "${GREEN}  ✓ Connected to: $ACCOUNT_ID${NC}"
echo ""

# ─── Show what will change ────────────────────────────────────────────────────
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
POLICY_EXISTS=false
aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null && POLICY_EXISTS=true

echo -e "${BLUE}── Configuration ────────────────────────────────────────────${NC}"
echo "  IAM user:         $USER_NAME"
echo "  Policy name:      $POLICY_NAME"
echo "  Policy ARN:       $POLICY_ARN"
echo "  Customer account: $CUSTOMER_ACCOUNT"
echo "  Role name:        $ROLE_NAME"
echo "  Role ARN:         $ROLE_ARN"
if $POLICY_EXISTS; then
  echo -e "  Action:           ${YELLOW}UPDATE existing policy (new version)${NC}"
else
  echo -e "  Action:           ${GREEN}CREATE new policy + attach to user${NC}"
fi
echo ""
read -p "Proceed? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; log "UPDATE_ABORTED" "operator_declined"; exit 1; }
echo ""

# ─── Build policy document ───────────────────────────────────────────────────
POLICY_FILE=$(mktemp /tmp/assume-role-policy-XXXXXX.json)
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeSpecificCustomerRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "$ROLE_ARN"
    }
  ]
}
EOF

# ─── Create or update policy ──────────────────────────────────────────────────
echo -e "${BLUE}── Applying AssumeRole policy ───────────────────────────────${NC}"

if $POLICY_EXISTS; then
  # Prune old non-default versions (IAM allows max 5 versions per policy)
  VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
  for VER in $VERSIONS; do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$VER"
    echo "  Pruned old version: $VER"
  done

  # Create new default version
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document file://"$POLICY_FILE" \
    --set-as-default
  echo -e "${GREEN}  ✓ Policy updated — new version set as default${NC}"
  log "UPDATED_POLICY_VERSION" "policy=$POLICY_ARN role_arn=$ROLE_ARN"
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://"$POLICY_FILE" \
    --description "Allows intermediate account to assume customer's S3 cross-account role"
  echo -e "${GREEN}  ✓ Policy created${NC}"
  log "CREATED_POLICY" "policy=$POLICY_ARN role_arn=$ROLE_ARN"

  # Attach to user
  aws iam attach-user-policy \
    --user-name "$USER_NAME" \
    --policy-arn "$POLICY_ARN"
  echo -e "${GREEN}  ✓ Policy attached to user: $USER_NAME${NC}"
  log "ATTACHED_POLICY" "user=$USER_NAME policy=$POLICY_ARN"
fi

# ─── Verify attachment ────────────────────────────────────────────────────────
ATTACHED=$(aws iam list-attached-user-policies --user-name "$USER_NAME" \
  --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyName" --output text)
if [ -n "$ATTACHED" ]; then
  echo -e "${GREEN}  ✓ Verified: policy is attached to $USER_NAME${NC}"
else
  echo -e "${RED}  ✗ Policy not found on user $USER_NAME after operation${NC}"
  log "VERIFY_FAILED" "user=$USER_NAME policy=$POLICY_ARN"
  exit 1
fi

# ─── Cleanup temp file ────────────────────────────────────────────────────────
rm -f "$POLICY_FILE"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  POLICY UPDATE COMPLETE                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  User $USER_NAME can now assume:"
echo "  $ROLE_ARN"
echo ""
echo -e "${YELLOW}Next step:${NC} Run scripts/health-check.sh to verify end-to-end access"
echo "Audit log: $AUDIT_LOG"
log "UPDATE_COMPLETE" "user=$USER_NAME policy=$POLICY_ARN role_arn=$ROLE_ARN"
