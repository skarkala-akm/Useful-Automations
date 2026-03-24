#!/bin/bash
# sandbox-runner.sh
# Safely executes an AWS IAM setup script in an isolated sandbox with full audit logging.
# Usage: bash sandbox-runner.sh <script-path> [script-args...]
#
# What it does:
#   1. Creates an isolated temp directory for all file operations
#   2. Captures all output (stdout + stderr) to a timestamped audit log
#   3. Verifies the AWS account before any changes
#   4. Runs the target script
#   5. Saves audit log to permanent location
#   6. Cleans up temp files (NOT the audit log)

set -e

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────────────
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-$HOME/aws-iam-audit-logs}"
SCRIPT_TO_RUN="$1"
shift || true
SCRIPT_ARGS="$@"

# ─── Validate input ──────────────────────────────────────────────────────────
if [ -z "$SCRIPT_TO_RUN" ]; then
  echo -e "${RED}Usage: bash sandbox-runner.sh <script-path> [script-args...]${NC}"
  echo "Example: bash sandbox-runner.sh scripts/setup-intermediate-account.sh --account-id 123456789012 --customer-id 987654321098 --access-mode write"
  exit 1
fi

if [ ! -f "$SCRIPT_TO_RUN" ]; then
  echo -e "${RED}Error: Script not found: $SCRIPT_TO_RUN${NC}"
  exit 1
fi

# ─── Audit log setup ─────────────────────────────────────────────────────────
mkdir -p "$AUDIT_LOG_DIR"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
SCRIPT_BASENAME=$(basename "$SCRIPT_TO_RUN" .sh)
AUDIT_LOG="$AUDIT_LOG_DIR/${TIMESTAMP}-${SCRIPT_BASENAME}.log"

# ─── Create sandbox ──────────────────────────────────────────────────────────
SANDBOX_DIR=$(mktemp -d /tmp/aws-iam-sandbox-XXXXXX)

# ─── Start logging ───────────────────────────────────────────────────────────
exec > >(tee -a "$AUDIT_LOG") 2>&1

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           AWS IAM SANDBOX — EXECUTION LOG                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "START_TIME:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "OPERATOR:     $(whoami)@$(hostname)"
echo "SANDBOX_DIR:  $SANDBOX_DIR"
echo "AUDIT_LOG:    $AUDIT_LOG"
echo "SCRIPT:       $SCRIPT_TO_RUN"
echo "ARGS:         $SCRIPT_ARGS"
echo ""

# ─── AWS Account verification ────────────────────────────────────────────────
echo -e "${BLUE}─── Pre-flight: AWS Account Verification ───────────────────${NC}"
CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1)
if [ $? -ne 0 ]; then
  echo -e "${RED}ERROR: Cannot connect to AWS. Check credentials.${NC}"
  echo "AWS_ERROR: $CALLER_IDENTITY"
  rm -rf "$SANDBOX_DIR"
  exit 1
fi

CURRENT_ACCOUNT=$(echo "$CALLER_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null || \
                  echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
CURRENT_USER=$(echo "$CALLER_IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Arn','unknown'))" 2>/dev/null || echo "unknown")

echo "AWS Account ID: $CURRENT_ACCOUNT"
echo "AWS Principal:  $CURRENT_USER"
echo ""

echo -e "${YELLOW}⚠️  You are about to run: $(basename $SCRIPT_TO_RUN)${NC}"
echo -e "${YELLOW}   This will make changes to AWS account: $CURRENT_ACCOUNT${NC}"
echo ""
read -p "Confirm this is the intended account. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted by operator."
  echo "ABORT_TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rm -rf "$SANDBOX_DIR"
  exit 1
fi

echo ""
echo -e "${GREEN}✓ Operator confirmed account. Proceeding.${NC}"
echo ""

# ─── Copy script to sandbox ──────────────────────────────────────────────────
echo -e "${BLUE}─── Sandbox Setup ──────────────────────────────────────────${NC}"
cp "$SCRIPT_TO_RUN" "$SANDBOX_DIR/"
chmod +x "$SANDBOX_DIR/$(basename $SCRIPT_TO_RUN)"

# Copy all skill scripts into sandbox so they're available if the target script calls them
SCRIPT_DIR=$(dirname "$(realpath "$SCRIPT_TO_RUN")")
for sibling in "$SCRIPT_DIR"/*.sh; do
  [[ "$(basename "$sibling")" != "$(basename "$SCRIPT_TO_RUN")" ]] && \
    cp "$sibling" "$SANDBOX_DIR/" 2>/dev/null || true
done

echo "Script copied to sandbox: $SANDBOX_DIR"
echo ""

# ─── Execute in sandbox ──────────────────────────────────────────────────────
echo -e "${BLUE}─── Script Execution ──────────────────────────────────────${NC}"
echo "EXEC_START: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

cd "$SANDBOX_DIR"
EXIT_CODE=0
bash "$(basename $SCRIPT_TO_RUN)" $SCRIPT_ARGS || EXIT_CODE=$?

echo ""
echo "EXEC_END:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "EXIT_CODE: $EXIT_CODE"

# ─── Cleanup sandbox ─────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}─── Cleanup ────────────────────────────────────────────────${NC}"
cd "$HOME"
rm -rf "$SANDBOX_DIR"
echo "Sandbox removed: $SANDBOX_DIR"

# ─── Final status ────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
if [ $EXIT_CODE -eq 0 ]; then
  echo "║  ✅  EXECUTION COMPLETE — SUCCESS                        ║"
else
  echo "║  ❌  EXECUTION COMPLETE — FAILED (exit code: $EXIT_CODE)    ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Audit log saved to: $AUDIT_LOG"
echo ""

if [ $EXIT_CODE -ne 0 ]; then
  echo -e "${RED}Script exited with error code $EXIT_CODE. Review the log above.${NC}"
  exit $EXIT_CODE
fi
