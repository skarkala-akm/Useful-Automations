# Customer Setup Guide

> This file is designed to be **shared with the customer**. It walks them through
> setting up the IAM role in their account. They do not need AWS expertise — the
> instructions are step-by-step and include a script option.

---

# AWS IAM Role Setup — Cross-Account S3 Access

Thank you for partnering with us. This guide walks you through a one-time setup
in your AWS account that allows our system to securely read/write to your S3
bucket using temporary credentials.

## What this setup does

- Creates an IAM role in your account (no permanent credentials shared with us)
- Our system assumes this role temporarily (credentials expire after 1 hour)
- Access is restricted to the specific S3 prefix we agree on
- You can revoke access at any time by deleting or modifying the role

---

## Prerequisites

- AWS CLI installed and configured with your account credentials, OR
- Access to the AWS Console with IAM and S3 permissions

---

## Option A: Automated Script (Recommended)

We have provided a setup guide that walks through each step manually (see Option B below). If you prefer an automated script, contact us and we can provide one tailored to your environment.

**Before starting:**
1. Have the **External ID** ready (we will send this to you via secure channel)
2. Know your **S3 bucket name** (or choose a new one)
3. Ensure your AWS CLI is configured with credentials for your account:
   ```bash
   aws sts get-caller-identity
   # Should show YOUR account ID
   ```

The script will:
- Create the IAM role `S3CrossAccountRole` with the correct trust policy
- Create and attach the S3 permissions policy
- Check if your S3 bucket exists (and offer to create it)
- Print the Role ARN and other values to send back to us

**Send us:**
- The Role ARN printed at the end
- Your S3 bucket name
- Your AWS region

---

## Option B: Manual Steps via AWS Console

### Step 1: Create the IAM Role

1. Log into [AWS Console](https://console.aws.amazon.com)
2. Go to **IAM → Roles → Create role**
3. Select **"Custom trust policy"**
4. Paste the following trust policy (replace values in CAPS with what we sent you):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "PRINCIPAL_ARN_WE_SENT_YOU"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "EXTERNAL_ID_WE_SENT_YOU_VIA_SECURE_CHANNEL"
        }
      }
    }
  ]
}
```

5. Click **Next**
6. Skip the permissions page for now (we'll add them in Step 2)
7. Name the role: `S3CrossAccountRole` (or your preferred name)
8. Click **Create role**

### Step 2: Create S3 Permissions Policy

1. Go to **IAM → Policies → Create policy**
2. Click **JSON** and paste the policy below (replace values in CAPS):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccessToAkamaiPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/akamai-logs/*"
    }
  ]
}
```

> For read access, use `s3:GetObject` instead. For read+write, include both.

3. Name the policy: `CustomerS3ForwarderPolicy`
4. Click **Create policy**

### Step 3: Attach Policy to Role

1. Go to **IAM → Roles → S3CrossAccountRole**
2. Click **Add permissions → Attach policies**
3. Search for `CustomerS3ForwarderPolicy`
4. Select it and click **Add permissions**

### Step 4: Get Your Role ARN

1. Go to **IAM → Roles → S3CrossAccountRole**
2. Copy the **ARN** at the top (looks like `arn:aws:iam::123456789012:role/S3CrossAccountRole`)

### Step 5: Create S3 Bucket (if needed)

If you don't have a bucket yet:
1. Go to **S3 → Create bucket**
2. Choose a globally unique name
3. Select your region
4. Keep default settings (block public access is already on by default — keep it that way)

---

## What to Send Back

Once setup is complete, reply to our email with:

```
Role ARN:   arn:aws:iam::YOUR_ACCOUNT_ID:role/S3CrossAccountRole
S3 Bucket:  your-bucket-name
AWS Region: us-east-1 (or whichever region you chose)
```

---

## Security Notes for Your Reference

- **We never receive your account credentials.** We only use the temporary credentials
  that AWS STS issues when we assume the role (they expire after 1 hour).
- **You can revoke access at any time** by deleting the `S3CrossAccountRole` IAM role.
- **Access is prefix-scoped.** We can only access objects under the agreed prefix
  (e.g., `akamai-logs/`). We cannot access the rest of your bucket.
- **ExternalId** prevents unauthorized role assumption. Even if someone discovers our
  Principal ARN, they cannot assume your role without the External ID.

---

## Questions?

Contact us at [Your support email or Slack channel].
