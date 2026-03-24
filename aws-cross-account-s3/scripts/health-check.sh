#!/bin/bash
# health-check.sh
# Runs a full health check on the cross-account IAM trust relationship.
# Tests: AssumeRole (should pass), S3 access (based on ACCESS_MODE),
#        security tests (no ExternalId, wrong ExternalId — both should fail).
#
# AWS AUTHENTICATION — set one of these before running:
#   export AWS_PROFILE=intermediate
#   export AWS_ACCESS_KEY_ID=... + AWS_SECRET_ACCESS_KEY=...
#   Or pass: --aws-profile intermediate
#
# Usage: bash health-check.sh [--aws-profile <profile>]
# Env vars: ROLE_ARN, EXTERNAL_ID, S3_BUCKET, S3_PREFIX, ACCESS_MODE

set -e

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Parse --aws-profile if provided ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile) export AWS_PROFILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PASS=0
FAIL=0
WARN=0

# ─── Audit logging ────────────────────────────────────────────────────────────
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$HOME/aws-iam-audit-logs}"
mkdir -p "$AUDIT_LOG_DIR"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-health-check.log"
exec > >(tee -a "$AUDIT_LOG") 2>&1

log_event() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] EVENT=$1 | OPERATOR=$(whoami) | $2" | tee -a "$AUDIT_LOG"
}

check_pass() { echo -e "${GREEN}  ✅ PASS: $1${NC}"; ((PASS++)); }
check_fail() { echo -e "${RED}  ❌ FAIL: $1${NC}"; ((FAIL++)); }
check_warn() { echo -e "${YELLOW}  ⚠️  WARN: $1${NC}"; ((WARN++)); }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         CROSS-ACCOUNT IAM HEALTH CHECK                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "START_TIME:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "OPERATOR:    $(whoami)@$(hostname)"
echo "AUDIT_LOG:   $AUDIT_LOG"
echo ""

# ─── Collect missing config ──────────────────────────────────────────────────
[ -z "$ROLE_ARN" ] && { echo -e "${YELLOW}Role ARN:${NC}"; read -r ROLE_ARN; }
[ -z "$EXTERNAL_ID" ] && { echo -e "${YELLOW}External ID:${NC}"; read -rs EXTERNAL_ID; echo ""; }
[ -z "$S3_BUCKET" ] && { echo -e "${YELLOW}S3 Bucket:${NC}"; read -r S3_BUCKET; }
[ -z "$S3_PREFIX" ] && { echo -e "${YELLOW}S3 Prefix (e.g. akamai-logs/):${NC}"; read -r S3_PREFIX; }
[ -z "$ACCESS_MODE" ] && { echo -e "${YELLOW}Access mode (read/write/readwrite):${NC}"; read -r ACCESS_MODE; }

echo ""
echo "Configuration:"
echo "  ROLE_ARN:    $ROLE_ARN"
echo "  S3_BUCKET:   $S3_BUCKET"
echo "  S3_PREFIX:   $S3_PREFIX"
echo "  ACCESS_MODE: $ACCESS_MODE"
echo ""

# ─── Test 1: Account identity ────────────────────────────────────────────────
echo -e "${BLUE}─── Test 1: Account Identity ───────────────────────────────${NC}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) && \
  check_pass "Connected to AWS account: $ACCOUNT" || check_fail "Cannot connect to AWS"
echo ""

# ─── Test 2: AssumeRole with correct ExternalId ──────────────────────────────
echo -e "${BLUE}─── Test 2: AssumeRole (correct ExternalId) ─────────────${NC}"
ASSUME_OUT=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "hc-$(date +%s)" \
  --external-id "$EXTERNAL_ID" 2>&1)

if echo "$ASSUME_OUT" | grep -q "AccessKeyId"; then
  check_pass "AssumeRole succeeded with correct ExternalId"
  TEMP_KEY_ID=$(echo "$ASSUME_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Credentials']['AccessKeyId'])")
  TEMP_SECRET=$(echo "$ASSUME_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Credentials']['SecretAccessKey'])")
  TEMP_TOKEN=$(echo "$ASSUME_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Credentials']['SessionToken'])")
  ASSUME_OK=true
else
  check_fail "AssumeRole FAILED: $ASSUME_OUT"
  ASSUME_OK=false
fi
echo ""

# ─── Test 3: S3 access (only if AssumeRole succeeded) ────────────────────────
if [ "$ASSUME_OK" = true ]; then
  echo -e "${BLUE}─── Test 3: S3 Access ──────────────────────────────────────${NC}"
  export AWS_ACCESS_KEY_ID="$TEMP_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$TEMP_SECRET"
  export AWS_SESSION_TOKEN="$TEMP_TOKEN"

  if [[ "$ACCESS_MODE" == "write" || "$ACCESS_MODE" == "readwrite" ]]; then
    TEST_KEY="${S3_PREFIX}health-check-$(date +%s).txt"
    WRITE_OUT=$(echo "health-check" | aws s3 cp - "s3://$S3_BUCKET/$TEST_KEY" 2>&1) && \
      check_pass "S3 PutObject to s3://$S3_BUCKET/$TEST_KEY" || \
      check_fail "S3 PutObject FAILED: $WRITE_OUT"
    # Clean up test object
    aws s3 rm "s3://$S3_BUCKET/$TEST_KEY" 2>/dev/null || true
  fi

  if [[ "$ACCESS_MODE" == "read" || "$ACCESS_MODE" == "readwrite" ]]; then
    LIST_OUT=$(aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX" 2>&1) && \
      check_pass "S3 ListObjects under s3://$S3_BUCKET/$S3_PREFIX" || \
      check_fail "S3 ListObjects FAILED: $LIST_OUT"
  fi

  # Restore original credentials
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
else
  check_warn "Skipping S3 tests — AssumeRole failed above"
fi
echo ""

# ─── Test 4: Security — no ExternalId (should FAIL) ─────────────────────────
echo -e "${BLUE}─── Test 4: Security — AssumeRole without ExternalId ──────${NC}"
NO_EXT_OUT=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "hc-no-extid-$(date +%s)" 2>&1) || true

if echo "$NO_EXT_OUT" | grep -qi "denied\|error\|invalid\|not authorized"; then
  check_pass "AssumeRole WITHOUT ExternalId was correctly DENIED"
else
  check_fail "SECURITY ISSUE: AssumeRole WITHOUT ExternalId SUCCEEDED — trust policy may be misconfigured"
fi
echo ""

# ─── Test 5: Security — wrong ExternalId (should FAIL) ───────────────────────
echo -e "${BLUE}─── Test 5: Security — AssumeRole with wrong ExternalId ───${NC}"
WRONG_EXT_OUT=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "hc-wrongext-$(date +%s)" \
  --external-id "wrong-id-intentional-fail-$(date +%s)" 2>&1) || true

if echo "$WRONG_EXT_OUT" | grep -qi "denied\|error\|invalid\|not authorized"; then
  check_pass "AssumeRole with WRONG ExternalId was correctly DENIED"
else
  check_fail "SECURITY ISSUE: AssumeRole with WRONG ExternalId SUCCEEDED — ExternalId condition may be missing"
fi
echo ""

# ─── Test 6: Credential age ──────────────────────────────────────────────────
echo -e "${BLUE}─── Test 6: Access Key Age ─────────────────────────────────${NC}"
IAM_USER="${IAM_USER_NAME:-}"
if [ -z "$IAM_USER" ]; then
  echo "  (Skipping — IAM_USER_NAME not set)"
  check_warn "Set IAM_USER_NAME env var to enable key age check"
else
  KEY_INFO=$(aws iam list-access-keys --user-name "$IAM_USER" \
    --query 'AccessKeyMetadata[*].[AccessKeyId,Status,CreateDate]' --output text 2>&1)
  echo "  $KEY_INFO"
  # Simple age warning — if CreateDate is more than ~80 days ago the key needs rotation soon
  echo "  ℹ️  Keys should be rotated every 90 days. Check CreateDate above."
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + WARN))
echo "╔══════════════════════════════════════════════════════════╗"
if [ $FAIL -eq 0 ]; then
  echo "║  ✅  HEALTH CHECK COMPLETE — ALL TESTS PASSED            ║"
else
  echo "║  ❌  HEALTH CHECK COMPLETE — $FAIL TEST(S) FAILED            ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Tests run:   $TOTAL"
echo "  Passed:      $PASS"
echo "  Failed:      $FAIL"
echo "  Warnings:    $WARN"
echo ""
echo "Audit log: $AUDIT_LOG"

if [ $FAIL -eq 0 ]; then
  log_event "HEALTH_CHECK" "result=PASS tests=$TOTAL passed=$PASS failed=$FAIL"
else
  log_event "HEALTH_CHECK" "result=FAIL tests=$TOTAL passed=$PASS failed=$FAIL"
  exit 1
fi
