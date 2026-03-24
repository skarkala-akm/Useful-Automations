# Email Templates — Customer Communication

These templates cover all situations where you need to communicate with the customer account holder. **You do not have access to the customer account** — all coordination is via email.

> 🔒 **Never send the External ID via plain email.** Use a secure channel: password manager share link, encrypted email, or your organization's secrets management tool. The email templates below include a placeholder `[SECURE CHANNEL]` for this reason.

---

## Template: `initial-setup-request`

Use when: Starting the setup for the first time.

```
Subject: AWS IAM Setup Request — Cross-Account S3 Access for [APPLICATION NAME]

Hi [Customer Contact Name],

To enable [APPLICATION NAME] to write/read logs to your S3 bucket, we need you to
set up an IAM role in your AWS account that grants our system temporary access.

Here is what we need you to configure:

---
ROLE CONFIGURATION

1. Role Name (your choice, suggested): S3CrossAccountRole

2. Trust Policy — allow only our specific IAM principal:
   Principal ARN: [PRINCIPAL_ARN]
   External ID:   [Send separately via secure channel — do not put in email]

   ⚠️ Important: The trust policy must use the exact Principal ARN above (not
   the account root). The External ID must be included as a condition. Both are
   required for the role assumption to succeed.

3. S3 Permissions Required:
   Bucket:  [S3_BUCKET — or ask customer to provide one]
   Prefix:  [S3_PREFIX]*
   Actions: [List based on ACCESS_MODE:
              write:     s3:PutObject, s3:PutObjectAcl
              read:      s3:GetObject, s3:ListBucket
              readwrite: s3:PutObject, s3:PutObjectAcl, s3:GetObject, s3:ListBucket]

---
WHAT TO SEND BACK

Once the role is created, please reply with:
  - Role ARN (e.g. arn:aws:iam::YOUR_ACCOUNT_ID:role/S3CrossAccountRole)
  - S3 bucket name
  - AWS region (e.g. us-east-1)

---
OPTIONAL: AUTOMATED SETUP

We have a script that automates the customer-side setup. If you prefer, we can
share it with you. It prompts for the External ID and bucket name, then creates
the role and policies automatically.

Please let us know if you have any questions.

Best regards,
[Your Name]
[Your Team / Organisation]
```

---

## Template: `external-id-rotation`

Use when: Rotating the External ID (annually or after suspected exposure).

```
Subject: ACTION REQUIRED — AWS External ID Rotation for [APPLICATION NAME]

Hi [Customer Contact Name],

As part of our routine security maintenance, we are rotating the External ID
used in our cross-account IAM trust policy. This is a scheduled annual rotation.

⚠️ This requires a coordinated change on both sides to avoid an access outage.

---
WHAT YOU NEED TO DO

In your AWS account, update the trust policy for role [ROLE_NAME]:

  Current External ID condition: [will be sent via secure channel]
  New External ID:               [will be sent via secure channel]

The new External ID will be sent to you separately via [SECURE CHANNEL].

Steps:
1. Log into your AWS account
2. Go to IAM → Roles → [ROLE_NAME]
3. Edit the trust policy
4. Replace the sts:ExternalId value with the new External ID
5. Save the change
6. Reply to this email confirming the update is live

---
TIMING

We propose to make this change on [PROPOSED DATE/TIME (UTC)].
We will update our application at the same time as you update the trust policy.

If this timing doesn't work, please suggest an alternative.

Expected downtime: Less than 1 minute during the switchover.

Best regards,
[Your Name]
[Your Team / Organisation]
```

---

## Template: `setup-confirmation`

Use when: The setup is complete and verified — informing the customer.

```
Subject: Confirmed — AWS Cross-Account S3 Access Working for [APPLICATION NAME]

Hi [Customer Contact Name],

We have successfully verified that the cross-account IAM setup is working correctly.

Test results:
  ✅ AssumeRole with correct ExternalId: SUCCESS
  ✅ S3 [read/write] to s3://[S3_BUCKET]/[S3_PREFIX]: SUCCESS
  ✅ AssumeRole without ExternalId: CORRECTLY DENIED
  ✅ AssumeRole with wrong ExternalId: CORRECTLY DENIED

The setup is now live. [APPLICATION NAME] will begin [reading/writing] to your
S3 bucket at the prefix [S3_PREFIX].

Please retain the following details for your records:
  - Role Name: [ROLE_NAME]
  - Our Principal ARN: [PRINCIPAL_ARN]
  - S3 Prefix: [S3_PREFIX]
  - Access type: [READ / WRITE / READWRITE]

If you have any questions or concerns, please don't hesitate to reach out.

Best regards,
[Your Name]
[Your Team / Organisation]
```

---

## Template: `change-request`

Use when: You need the customer to change something (e.g., add a new prefix, update permissions).

```
Subject: AWS IAM Change Request — [BRIEF DESCRIPTION] for [APPLICATION NAME]

Hi [Customer Contact Name],

We have a change request for the IAM role in your account that supports
[APPLICATION NAME].

---
CHANGE REQUIRED

Current configuration:
  [Describe what is there now]

Requested change:
  [Describe exactly what needs to change]

Reason:
  [Brief explanation — e.g. "We are adding a new log stream that requires access
   to an additional S3 prefix."]

---
IMPACT

  Expected downtime: [None / X minutes]
  Risk: [Low / Medium — explain if not Low]

---
WHAT TO SEND BACK

After making the change, please confirm:
  [ ] Change has been applied
  [ ] [Any new ARNs or values we need]

Best regards,
[Your Name]
[Your Team / Organisation]
```

---

## External ID Format Convention

External IDs must follow this naming convention:

```
akamai-<customer-name>-<UUID-v4>
```

| Part | Description | Example |
|---|---|---|
| `akamai-` | Fixed prefix — identifies the system | `akamai-` |
| `<customer-name>` | Short slug for the customer (lowercase, no spaces) | `acmecorp` |
| `<UUID-v4>` | Random UUID v4 — generate at https://www.uuidgenerator.net/version4 | `550e8400-e29b-41d4-a716-446655440000` |

Full example: `akamai-acmecorp-550e8400-e29b-41d4-a716-446655440000`

This format makes External IDs identifiable during IAM audits and troubleshooting, without exposing sensitive values.

---

## Secure Channel Options for External ID

Never send the External ID in plain email. Use one of:

| Option | How |
|---|---|
| Password manager share | 1Password, Bitwarden, LastPass — create a secure share link with expiry |
| Encrypted email | PGP/GPG if both parties have keys |
| Organization secrets tool | HashiCorp Vault, AWS Secrets Manager, Azure Key Vault |
| Secure file transfer | Tresorit, ShareFile — NOT Google Drive, Dropbox, or email attachments |
| Phone / video call | Read it out verbally — confirm the recipient writes it down correctly |
