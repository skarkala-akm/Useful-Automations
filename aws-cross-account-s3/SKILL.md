---
name: aws-cross-account-s3
description: >
  Comprehensive skill for setting up, managing, and maintaining AWS cross-account
  S3 access where an intermediate (broker) account manages static credentials on
  behalf of applications, and a customer account provides temporary credentials
  via IAM role assumption. Use this skill whenever users mention: cross-account S3
  access, IAM role assumption, temporary credentials, credential rotation, ExternalId,
  AssumeRole setup, S3 read/write access from another account, intermediate account
  credential management, customer account IAM role, sandbox script execution, audit
  logging for IAM changes, or any variation of "account A account B S3". Always
  trigger this skill — never rely on memory for this setup. Also trigger for
  ongoing management tasks: credential rotation, health checks, policy reviews,
  communicating with customers about IAM changes, and audit trail review.
---

# AWS Cross-Account S3 Access — Full Lifecycle Management Skill

## Architecture Overview

```
┌─────────────────────────────────────┐
│  INTERMEDIATE ACCOUNT (Broker/App)  │
│                                     │
│  IAM User (static credentials)      │
│  → Policy: sts:AssumeRole only      │
│  → Credentials stored securely      │
│  → Rotated every 90 days            │
└──────────────┬──────────────────────┘
               │ AssumeRole + ExternalId
               ▼ (returns temp credentials, 1hr TTL)
┌─────────────────────────────────────┐
│  CUSTOMER ACCOUNT (S3 Owner)        │
│                                     │
│  IAM Role (no static credentials)   │
│  → Trust: specific Principal ARN    │
│  → Trust: ExternalId condition      │
│  → Permission: S3 read/write/both   │
│                    ↓                │
│  S3 Bucket (prefix-scoped)          │
└─────────────────────────────────────┘
```

**Key principle:** The customer account never issues static credentials. The intermediate account holds static credentials only to call `sts:AssumeRole`. All actual S3 access uses short-lived temporary credentials (1 hour TTL) vended by STS.

---

## Quick Navigation

| I want to… | Go to |
|---|---|
| Set up from scratch | [SETUP WORKFLOW](#setup-workflow) |
| Run scripts safely | [SANDBOX EXECUTION](#sandbox-execution) |
| Draft an email to the customer | [CUSTOMER COMMUNICATION](#customer-communication) |
| Update policy after customer responds | [Step 4 — Customer Responds](#step-4--customer-responds--update-intermediate-account-policy) |
| Rotate credentials (90-day task) | [CREDENTIAL ROTATION](#credential-rotation) |
| Rotate External ID | [EXTERNAL ID ROTATION](#external-id-rotation) |
| Review IAM policies quarterly | [POLICY REVIEW](#policy-review) |
| Run a health check | [HEALTH CHECK](#health-check) |
| Read the audit log | [AUDIT LOG](#audit-log) |
| Troubleshoot an error | [TROUBLESHOOTING](#troubleshooting) |

---

## INTERACTION STYLE

**Always guide the user one step at a time.** After presenting each step:
- Wait for the user to confirm they've completed it (e.g. "done", "it worked", pasting output)
- Only then present the next step
- Never dump all steps at once

**Always provide the script file alongside any command.** Whenever a step requires running a script, use `present_files` to share the script file at the same time as showing the command. Never show a `bash script.sh ...` command without first ensuring the script has been presented for download.

**Always guide the user through AWS CLI authentication before running any script.** Before Step 1, instruct the user to authenticate their CLI to the intermediate account. Show them both options:
- Option A (recommended): `aws configure --profile <name>` + `export AWS_PROFILE=<name>`
- Option B: export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`

Then ask them to run `aws sts get-caller-identity` and confirm the account ID matches before proceeding.

This applies to the setup workflow and all other multi-step processes (rotation, teardown, etc.).

---

## SETUP WORKFLOW

### Step 0 — Collect Configuration

Ask the user only for the values they know. Everything else has a safe default — Claude will generate it, and the setup script will check for name conflicts before creating anything.

**You must collect these — no defaults exist:**

| Variable | Description | Example |
|---|---|---|
| `INTERMEDIATE_ACCOUNT_ID` | AWS Account ID of the broker/app account | `252685663126` |
| `CUSTOMER_ACCOUNT_ID` | AWS Account ID of the S3 owner | `613602870030` |
| `ACCESS_MODE` | What the app needs: `read`, `write`, or `readwrite` | `write` |

**These have defaults — only ask if the user has a preference:**

| Variable | Default | Notes |
|---|---|---|
| `IAM_USER_NAME` | `s3-forwarder-user` | Must be unique in the intermediate account |
| `ASSUME_POLICY_NAME` | `AllowAssumeCustomerS3Role` | Script checks for conflicts and suggests alternatives |
| `AWS_REGION` | `us-east-1` | Region of the customer's S3 bucket |

**Never ask for these — they come from the customer:**

| Variable | Source | When available |
|---|---|---|
| `ROLE_ARN` | Customer's reply email | After Step 3 |
| `S3_BUCKET` | Customer's reply email | After Step 3 |

> ℹ️ The customer's role name, bucket name, and policy name are entirely their choice. Do not suggest or assume specific names for these — wait until they respond in Step 4.

---

### Step 1 — Intermediate Account Setup

> ✅ Run with **intermediate account credentials**. You have access to this account.

Run the setup script in the sandbox (see [SANDBOX EXECUTION](#sandbox-execution)):

```bash
bash scripts/setup-intermediate-account.sh \
  --account-id      $INTERMEDIATE_ACCOUNT_ID \
  --customer-id     $CUSTOMER_ACCOUNT_ID \
  --access-mode     $ACCESS_MODE \
  [--user-name      $IAM_USER_NAME] \
  [--policy-name    $ASSUME_POLICY_NAME] \
  [--region         $AWS_REGION]
```

Flags in `[brackets]` are optional — safe defaults are used if omitted.

The script will:
1. Verify you are in the correct AWS account before touching anything
2. Check `IAM_USER_NAME` and `ASSUME_POLICY_NAME` do not already exist — if they do, suggest conflict-free alternatives (e.g. `s3-forwarder-user-2`)
3. Create the IAM user
4. Generate a structured External ID (`akamai-<slug>-<uuid>` format)
5. Create access keys and save to `credentials-<timestamp>.json` (chmod 600)
6. Print a ready-to-use summary of all values needed for the customer email
7. Log every action to the audit log

> 🔒 Store the `credentials-<timestamp>.json` output securely — credentials appear only once.

> ℹ️ The AssumeRole policy is **not created yet** — that happens in Step 4 once the customer sends back their actual Role ARN.

---

### Step 2 — Communicate to Customer

Before drafting the email, ask about `S3_PREFIX`:

| Variable | Description | Example | If no opinion |
|---|---|---|---|
| `S3_PREFIX` | S3 key prefix the app will read/write under | `akamai-logs/` | Leave blank — let the customer decide and tell you in their reply |

> ℹ️ If neither side has a strong preference, omit the prefix from the email and ask the customer to propose one. They often have naming conventions for their bucket layout. Capture whatever they reply with in Step 4.

You **do not have access** to the customer account. You must email them.

See [CUSTOMER COMMUNICATION](#customer-communication) → **"Initial Setup Request"** template.

Information to send:
- `PRINCIPAL_ARN`
- `EXTERNAL_ID` (confidential — use secure channel)
- Required S3 permissions (based on `ACCESS_MODE`)
- `S3_PREFIX`

---

### Step 3 — Customer Sets Up Their Account

> ⚠️ You cannot do this. The customer runs this in their account.

Share the manual steps from `references/customer-guide.md` with the customer.

The customer will create:
- IAM role with **their own chosen name** (e.g. `AcmeCorpLogDeliveryRole`) with trust policy scoped to your `PRINCIPAL_ARN` + `EXTERNAL_ID`
- S3 permissions policy scoped to their chosen `S3_BUCKET` and `S3_PREFIX`
- S3 bucket with **their own chosen name** (if needed)

> ℹ️ Do not assume the customer will use the role or bucket names you suggested. Wait for their response in Step 4 before creating any policy that references their resources.

---

### Step 4 — Customer Responds & Update Intermediate Account Policy

Customer emails back their actual values — role name, bucket name, and region are **entirely their choice**:
- `ROLE_ARN` — e.g. `arn:aws:iam::613602870030:role/AcmeCorpLogDeliveryRole`
- `S3_BUCKET` — e.g. `acmecorp-inbound-logs`
- `AWS_REGION`

**Now create the AssumeRole policy** using the customer's actual Role ARN:

```bash
bash scripts/update-assume-role-policy.sh \
  --role-arn    "<paste Role ARN from customer email>" \
  --user-name   $IAM_USER_NAME \
  --account-id  $INTERMEDIATE_ACCOUNT_ID \
  [--policy-name $ASSUME_POLICY_NAME]
```

The script handles both cases automatically:
- **First run:** creates the policy and attaches it to the IAM user
- **Customer renames their role later:** creates a new policy version scoped to the new ARN, sets it as default — no detach/re-attach needed

> 🔒 Log this action — the script writes to the audit log automatically.

> ⚠️ If the customer later renames their role, re-run this script with the new Role ARN. The S3 bucket name does not appear in the intermediate account policy — only the Role ARN matters here.

---

### Step 5 — Configure Application & Verify

```bash
# Configure your application's environment
export AWS_ACCESS_KEY_ID="<from credentials.json>"
export AWS_SECRET_ACCESS_KEY="<from credentials.json>"
export AWS_ROLE_ARN="$ROLE_ARN"
export AWS_EXTERNAL_ID="$EXTERNAL_ID"
export AWS_REGION="$AWS_REGION"
export S3_BUCKET="$S3_BUCKET"
```

Then run the [HEALTH CHECK](#health-check) to verify everything works.

---

## AWS AUTHENTICATION SETUP

Before running any script, your terminal must be authenticated to the intermediate AWS account. Choose one method:

### Option A — Named profile (recommended for multi-account work)

```bash
# Configure a named profile for the intermediate account
aws configure --profile intermediate
# Prompts for: Access Key ID, Secret Access Key, region, output format

# Verify it points to the right account
aws sts get-caller-identity --profile intermediate

# Set it active for this terminal session
export AWS_PROFILE=intermediate
```

### Option B — Environment variables

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"

# Verify
aws sts get-caller-identity
```

### Option C — IAM Identity Center (SSO)

```bash
aws configure sso --profile intermediate
aws sso login --profile intermediate
export AWS_PROFILE=intermediate
aws sts get-caller-identity
```

> ⚠️ All scripts call `aws sts get-caller-identity` at startup and confirm the account ID before making any changes. If the account does not match, the script will warn you and ask for confirmation before proceeding.

---

## SANDBOX EXECUTION

> **Always run scripts via `sandbox-runner.sh`.** It creates an isolated working directory, verifies the AWS account, captures all output to the audit log, and cleans up temp files afterwards.

### Usage

```bash
bash scripts/sandbox-runner.sh scripts/setup-intermediate-account.sh \
  --account-id  252685663126 \
  --customer-id 613602870030 \
  --access-mode write
```

The runner accepts any script in `scripts/` as its first argument, followed by that script's own flags:

```bash
# Step 1 — initial setup
bash scripts/sandbox-runner.sh scripts/setup-intermediate-account.sh \
  --account-id $INTERMEDIATE_ACCOUNT_ID \
  --customer-id $CUSTOMER_ACCOUNT_ID \
  --access-mode $ACCESS_MODE

# Step 4 — attach policy after customer responds
bash scripts/sandbox-runner.sh scripts/update-assume-role-policy.sh \
  --role-arn   "$ROLE_ARN" \
  --user-name  $IAM_USER_NAME \
  --account-id $INTERMEDIATE_ACCOUNT_ID

# Credential rotation
bash scripts/sandbox-runner.sh scripts/rotate-credentials.sh \
  --user    $IAM_USER_NAME \
  --account $INTERMEDIATE_ACCOUNT_ID

# Teardown
bash scripts/sandbox-runner.sh scripts/teardown.sh \
  --user    $IAM_USER_NAME \
  --account $INTERMEDIATE_ACCOUNT_ID \
  --policy  $ASSUME_POLICY_NAME
```

> ℹ️ `health-check.sh` does not modify any resources — run it directly without the sandbox wrapper.

### Pre-flight checklist before running any script

- [ ] AWS authentication is set (see [AWS AUTHENTICATION SETUP](#aws-authentication-setup))
- [ ] `aws sts get-caller-identity` shows the **correct account ID**
- [ ] Audit log directory exists: `mkdir -p ~/aws-iam-audit-logs`

---

## CUSTOMER COMMUNICATION

You do not have access to the customer account. All coordination is via email.

See `references/email-templates.md` for full templates. Below are the situations:

| Situation | Template to use |
|---|---|
| First setup — asking customer to create role | `initial-setup-request` |
| External ID rotation — customer must update trust policy | `external-id-rotation` |
| Customer role or bucket change needed | `change-request` |
| Confirming setup is working | `setup-confirmation` |

Always include in emails:
- Your `PRINCIPAL_ARN` (never the access keys or External ID in plain email)
- What you need the customer to **do** (specific actions)
- What they need to **send back** to you
- A deadline or SLA expectation

For the External ID: use a **secure channel** (password manager share, encrypted email, or your organization's secrets tool) — never send via plain email.

---

## CREDENTIAL ROTATION

> ⏰ **Schedule:** Every 90 days. The intermediate account manages this — no customer involvement needed.

```bash
# === STEP 1: Create new access key ===
NEW_KEY=$(aws iam create-access-key --user-name $IAM_USER_NAME)
NEW_KEY_ID=$(echo $NEW_KEY | jq -r '.AccessKey.AccessKeyId')
NEW_SECRET=$(echo $NEW_KEY | jq -r '.AccessKey.SecretAccessKey')
echo "New Key ID: $NEW_KEY_ID"

# === STEP 2: Update application configuration ===
# Update /opt/envoy/.env or your secrets manager with new credentials
# Then restart the application

# === STEP 3: Verify the new credentials work ===
# (See HEALTH CHECK section)

# === STEP 4: Deactivate old key ===
OLD_KEY_ID="<previous key id>"
aws iam update-access-key \
  --user-name $IAM_USER_NAME \
  --access-key-id $OLD_KEY_ID \
  --status Inactive
echo "Old key $OLD_KEY_ID deactivated"

# === STEP 5: Delete old key (only after confirming new key works) ===
aws iam delete-access-key \
  --user-name $IAM_USER_NAME \
  --access-key-id $OLD_KEY_ID
echo "Old key $OLD_KEY_ID deleted"
```

> ⚠️ AWS allows max **2 access keys** per user. Always delete the old key.

**Log this action:** See [AUDIT LOG](#audit-log) — record `ROTATED_CREDENTIALS` event.

---

## EXTERNAL ID ROTATION

> ⏰ **Schedule:** Annually, or immediately if suspected exposure.
> ⚠️ **Requires customer coordination.** Plan a maintenance window.

### External ID Format

External IDs must follow this naming convention:

```
akamai-<customer-name>-<UUID-v4>
```

Example: `akamai-acmecorp-550e8400-e29b-41d4-a716-446655440000`

This format makes it easy to identify which customer an External ID belongs to during audits and troubleshooting.

### Rotation Steps

```bash
# Step 1: Generate a new UUID v4
# Visit https://www.uuidgenerator.net/version4 and click Generate
# Then construct the full External ID:
NEW_EXTERNAL_ID="akamai-<customer-name>-<UUID>"
# Example: NEW_EXTERNAL_ID="akamai-acmecorp-550e8400-e29b-41d4-a716-446655440000"
echo "New External ID: $NEW_EXTERNAL_ID"
# Store in your secrets manager before proceeding
```

Email the customer using the `external-id-rotation` template from `references/email-templates.md`. Include the new External ID via **secure channel only** — never plain email.

The customer must:
1. Update their trust policy `sts:ExternalId` condition with the new value
2. Confirm the change is deployed before you proceed

```bash
# Step 3: Update your application environment
export AWS_EXTERNAL_ID="$NEW_EXTERNAL_ID"
# Update /opt/envoy/.env or secrets manager, then restart application

# Step 4: Validate new External ID works — should SUCCEED
aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name ext-id-rotation-validation \
  --external-id "$NEW_EXTERNAL_ID"
# Expected: Returns Credentials block with AccessKeyId, SecretAccessKey, SessionToken

# Step 5: Confirm old External ID no longer works — should FAIL
aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name ext-id-old-check \
  --external-id "$OLD_EXTERNAL_ID"
# Expected: AccessDenied — if this SUCCEEDS, customer has NOT updated their trust policy yet

# Step 6: Full end-to-end verification
# (See HEALTH CHECK section)
```

**Log this action:** Record `ROTATED_EXTERNAL_ID` event in [AUDIT LOG](#audit-log).

---

## POLICY REVIEW

> ⏰ **Schedule:** Quarterly. Intermediate account side only.

```bash
# 1. List policies attached to IAM user
aws iam list-attached-user-policies --user-name $IAM_USER_NAME

# 2. Review the assume-role policy
POLICY_ARN="arn:aws:iam::$INTERMEDIATE_ACCOUNT_ID:policy/$ASSUME_POLICY_NAME"
VERSION=$(aws iam get-policy --policy-arn $POLICY_ARN --query 'Policy.DefaultVersionId' --output text)
aws iam get-policy-version --policy-arn $POLICY_ARN --version-id $VERSION

# 3. List all access keys and their age
aws iam list-access-keys --user-name $IAM_USER_NAME

# 4. Check for inline policies (should be none)
aws iam list-user-policies --user-name $IAM_USER_NAME
```

**Policy must:**
- Allow only `sts:AssumeRole`
- Target only the specific `ROLE_ARN` in the customer account (not `*`)
- Have no extra permissions

**Access keys must:**
- Be no older than 90 days (check `CreateDate`)
- Have no more than 1 active key

---

## HEALTH CHECK

Run after any change, or any time you want to verify the trust relationship is intact.

```bash
# Test 1: AssumeRole — should SUCCEED and return credentials
aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name health-check-$(date +%s) \
  --external-id "$EXTERNAL_ID"

# If that succeeds, extract temp credentials and test S3 access
CREDS=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name s3-test \
  --external-id "$EXTERNAL_ID")

export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')

# Test S3 write (if ACCESS_MODE includes write)
echo "health-check" > /tmp/hc-test.txt
aws s3 cp /tmp/hc-test.txt s3://$S3_BUCKET/${S3_PREFIX}health-check-$(date +%s).txt
aws s3 rm s3://$S3_BUCKET/${S3_PREFIX}health-check-$(date +%s).txt
rm /tmp/hc-test.txt

# Test S3 read (if ACCESS_MODE includes read)
aws s3 ls s3://$S3_BUCKET/$S3_PREFIX

# SECURITY TESTS — these should FAIL
aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name test-no-extid 2>&1 | grep -i "error\|denied"

aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name test-wrong-extid \
  --external-id "wrong-id-intentional-fail" 2>&1 | grep -i "error\|denied"

# Restore original credentials
unset AWS_SESSION_TOKEN
```

---

## AUDIT LOG

All actions that modify IAM resources or credentials **must** be logged. This provides an audit trail for security reviews.

### Log format

```bash
# Append to audit log
AUDIT_LOG=~/aws-iam-audit-logs/audit.log
mkdir -p ~/aws-iam-audit-logs

log_event() {
  local EVENT_TYPE="$1"
  local DETAILS="$2"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | EVENT=$EVENT_TYPE | OPERATOR=$(whoami) | ACCOUNT=$INTERMEDIATE_ACCOUNT_ID | USER=$IAM_USER_NAME | $DETAILS" >> "$AUDIT_LOG"
}

# Usage examples:
log_event "CREATED_IAM_USER" "user=$IAM_USER_NAME"
log_event "CREATED_ACCESS_KEY" "key_id=$NEW_KEY_ID"
log_event "ROTATED_CREDENTIALS" "old_key=$OLD_KEY_ID new_key=$NEW_KEY_ID"
log_event "ROTATED_EXTERNAL_ID" "reason=annual_rotation"
log_event "HEALTH_CHECK" "result=PASS"
log_event "POLICY_REVIEW" "result=no_changes_needed"
log_event "SENT_CUSTOMER_EMAIL" "template=initial-setup-request recipient=customer@example.com"
```

### Loggable events

| Event | When to log |
|---|---|
| `CREATED_IAM_USER` | Step 1 of setup |
| `CREATED_ACCESS_KEY` | Step 1 of setup, or credential rotation |
| `ATTACHED_POLICY` | Any time a policy is attached |
| `ROTATED_CREDENTIALS` | Every 90-day rotation |
| `ROTATED_EXTERNAL_ID` | Annual or emergency rotation |
| `DELETED_ACCESS_KEY` | After rotation, after teardown |
| `HEALTH_CHECK` | After each health check |
| `POLICY_REVIEW` | After each quarterly review |
| `SENT_CUSTOMER_EMAIL` | Any time you email the customer |
| `TEARDOWN` | When removing the entire setup |

### Reviewing the audit log

```bash
# View all events
cat ~/aws-iam-audit-logs/audit.log

# Filter by event type
grep "ROTATED_CREDENTIALS" ~/aws-iam-audit-logs/audit.log

# Events in the last 90 days
awk -v d="$(date -d '90 days ago' -u +%Y-%m-%dT%H:%M:%SZ)" '$1 >= d' ~/aws-iam-audit-logs/audit.log
```

---

## TROUBLESHOOTING

| Error message | Root cause | Fix |
|---|---|---|
| "User is not authorized to perform: sts:AssumeRole" | AssumeRole policy not attached, or wrong Role ARN | Check policy is attached; verify Role ARN matches exactly |
| "Not authorized to assume this role" | Wrong Principal ARN in trust policy, or ExternalId mismatch | Confirm customer's trust policy has your exact PRINCIPAL_ARN; confirm ExternalId matches case-sensitively |
| "Access Denied" on S3 PutObject | S3 policy not attached to role, or wrong prefix | Customer: verify policy attached; confirm bucket and prefix are correct |
| "Access Denied" on S3 GetObject | Role only has PutObject — check ACCESS_MODE | Customer: add `s3:GetObject` to the role policy |
| "InvalidClientTokenId" | Access key deleted or deactivated | Rotate credentials (see CREDENTIAL ROTATION) |
| "ExpiredTokenException" | Session token from AssumeRole expired (1hr TTL) | Re-run AssumeRole to get fresh credentials |
| "Unable to locate credentials" | App not configured with credentials | Update `/opt/envoy/.env` and restart |
| "The role has a session duration limit" | Session > 1 hour requested | Default is 3600s; do not exceed `MaxSessionDuration` on the role |

---

## REFERENCE FILES

- `references/email-templates.md` — All email templates for customer communication
- `references/customer-guide.md` — What to send the customer to set up their account
- `references/policies.md` — All IAM/S3 policy JSON for read, write, and readwrite modes
- `scripts/setup-intermediate-account.sh` — **Step 1** — create IAM user, generate External ID, create access keys; checks for naming conflicts and suggests alternatives
- `scripts/update-assume-role-policy.sh` — **Step 4** — create or update the AssumeRole policy once the customer sends their Role ARN
- `scripts/sandbox-runner.sh` — Safety wrapper: isolated temp dir, account verification, full audit logging
- `scripts/rotate-credentials.sh` — 90-day credential rotation with verification and audit logging
- `scripts/health-check.sh` — Full health check with S3 tests and security tests
- `scripts/teardown.sh` — Clean removal of all intermediate account resources with audit logging
