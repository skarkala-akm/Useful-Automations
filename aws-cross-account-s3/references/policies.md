# IAM & S3 Policy Templates

All policies used in the cross-account S3 access setup.

---

## Intermediate Account Policies

### AssumeRole Policy (Intermediate Account)

Grants the IAM user in the intermediate account permission to assume the role in the customer account. Scoped to the **specific role ARN only** — never use `*`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAssumeSpecificCustomerRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::CUSTOMER_ACCOUNT_ID:role/ROLE_NAME"
    }
  ]
}
```

---

## Customer Account Policies

### Trust Policy (Customer Account Role)

Controls who can assume the role. **Must** use specific Principal ARN and ExternalId condition. Never use account root (`arn:aws:iam::ACCOUNT_ID:root`).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::INTERMEDIATE_ACCOUNT_ID:user/IAM_USER_NAME"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "YOUR_EXTERNAL_ID"
        }
      }
    }
  ]
}
```

---

### S3 Permissions Policies

#### Write Only (`ACCESS_MODE=write`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowWriteToPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws:s3:::S3_BUCKET/S3_PREFIX*"
    }
  ]
}
```

#### Read Only (`ACCESS_MODE=read`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadFromPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::S3_BUCKET/S3_PREFIX*"
    },
    {
      "Sid": "AllowListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::S3_BUCKET",
      "Condition": {
        "StringLike": {
          "s3:prefix": "S3_PREFIX*"
        }
      }
    }
  ]
}
```

#### Read + Write (`ACCESS_MODE=readwrite`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadWriteToPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::S3_BUCKET/S3_PREFIX*"
    },
    {
      "Sid": "AllowListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::S3_BUCKET",
      "Condition": {
        "StringLike": {
          "s3:prefix": "S3_PREFIX*"
        }
      }
    }
  ]
}
```

---

## Security Notes

| Risk | Mitigation |
|---|---|
| Confused deputy attack | ExternalId condition in trust policy — required |
| Overly broad S3 access | Always scope to `S3_PREFIX*`, never `*` |
| Account-wide trust | Use specific Principal ARN, never account root |
| Excess permissions | Only grant the actions the application actually needs |
| Long-lived credentials | Access keys rotate every 90 days; role credentials expire after 1 hour |
