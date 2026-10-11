# IAM + AWS Systems Manager Deployment Setup

This is the step-by-step guide for the credential model the CI/CD pipeline (`.github/workflows/deploy.yml`) actually uses: a dedicated **IAM user** authenticates GitHub Actions to AWS, and deployment runs over **AWS Systems Manager (SSM) Run Command** — there is no SSH key, no open port 22 needed for CI, and no SSH host-key management.

If you previously set up `EC2_SSH_KEY` / `EC2_KNOWN_HOSTS` secrets for an older SSH-based version of this pipeline, they are no longer used and can be deleted from GitHub.

---

## 0. Why this architecture

| | SSH-based (previous) | IAM + SSM (this guide) |
|---|---|---|
| Credential in GitHub | A private SSH key | AWS IAM user access keys |
| Port 22 needed for CI | Yes | No |
| Host identity verification | Manual known_hosts fingerprint | Handled by AWS (TLS to the SSM API, instance identity verified by AWS, not by GitHub Actions) |
| File transfer | `rsync` over SSH | Private S3 bucket |
| Revoking CI's access | Remove the key from `authorized_keys` | Delete the IAM access key (or the whole IAM user) |
| Audit trail | Whatever your EC2 auth logs capture | Full command history in AWS CloudTrail / SSM console, per command, with output |

Two different AWS identities are involved and it's easy to conflate them:
- **The IAM user** (`github-actions-deploy`) — used by GitHub Actions itself to call AWS APIs (`ssm:SendCommand`, `s3:PutObject`). Lives in IAM, has access keys.
- **The EC2 instance role** — attached directly to your EC2 instance so the SSM Agent running on it can register with AWS Systems Manager and receive commands. This is a role, not a user, and has no access keys — EC2 assumes it automatically.

Both are required. The IAM user alone cannot make SSM Run Command work if the instance itself has no role allowing it to be managed.

---

## 1. Architecture

```
GitHub Actions workflow
   │
   │  1. aws s3 cp compose.yaml + deploy/  ──────────────▶  S3 bucket (private)
   │     (using IAM user access keys)                          │
   │                                                            │ 2. instance pulls
   │  3. aws ssm send-command                                   │    the same object
   │     "run deploy/deploy.sh pull-deploy"                     ▼
   └────────────────────────────────────────────────▶  EC2 instance
                                                         (SSM Agent, instance role)
                                                              │
                                                              ▼
                                                    docker compose pull + up
                                                    (images from GHCR, public)
```

No inbound connection from GitHub to EC2 at all — the EC2 instance's SSM Agent makes an outbound connection to AWS Systems Manager and polls for commands. This is why no SSH port needs to be open to GitHub's IP ranges.

---

## 2. Prerequisites

- AWS CLI installed and configured on **your own machine** with sufficiently privileged credentials (your normal admin/account user — not the IAM user you're about to create, which deliberately won't have permission to create other IAM resources).
- Your EC2 instance ID (AWS Console → EC2 → Instances → copy the `i-xxxxxxxxxxxxxxxxx` value), region, and AWS account ID:
  ```bash
  aws sts get-caller-identity --query Account --output text
  ```
- The app already deployed once manually (per `AWS_DEPLOYMENT.md`), so `compose.yaml` and `deploy/` already exist at `EC2_APP_DIR` on the instance.

Set these as shell variables now — every command below reuses them:
```bash
export REGION="us-east-1"                      # your EC2's region
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export EC2_INSTANCE_ID="i-0123456789abcdef0"    # your actual instance ID
export BUCKET_NAME="replit-porject-deploy-$(openssl rand -hex 4)"   # must be globally unique
```

---

## 3. One-time AWS setup

### 3.1 Create the S3 bucket for deploy artifacts

```bash
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  $( [[ "$REGION" != "us-east-1" ]] && echo "--create-bucket-configuration LocationConstraint=$REGION" )

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Optional but recommended — automatically expire old deploy artifacts so the bucket doesn't grow forever:
```bash
cat > /tmp/lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-old-releases",
      "Filter": { "Prefix": "releases/" },
      "Status": "Enabled",
      "Expiration": { "Days": 14 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration file:///tmp/lifecycle.json
```

Write down `$BUCKET_NAME` — it becomes the GitHub variable `DEPLOY_S3_BUCKET`.

### 3.2 Create the EC2 instance role (lets SSM manage the box)

```bash
cat > /tmp/ec2-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name Replit-Porject-EC2-SSM-Role \
  --assume-role-policy-document file:///tmp/ec2-trust-policy.json

aws iam attach-role-policy \
  --role-name Replit-Porject-EC2-SSM-Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

cat > /tmp/ec2-s3-read-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::$BUCKET_NAME/releases/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name Replit-Porject-EC2-SSM-Role \
  --policy-name ReadDeployArtifacts \
  --policy-document file:///tmp/ec2-s3-read-policy.json

aws iam create-instance-profile --instance-profile-name Replit-Porject-EC2-SSM-Profile
aws iam add-role-to-instance-profile \
  --instance-profile-name Replit-Porject-EC2-SSM-Profile \
  --role-name Replit-Porject-EC2-SSM-Role
```

Wait about 10 seconds for IAM to propagate, then attach the instance profile to your **already-running** instance — this does not require stopping it:
```bash
aws ec2 associate-iam-instance-profile \
  --instance-id "$EC2_INSTANCE_ID" \
  --iam-instance-profile Name=Replit-Porject-EC2-SSM-Profile
```

(Equivalent console path: EC2 → Instances → select instance → **Actions → Security → Modify IAM role** → choose `Replit-Porject-EC2-SSM-Profile`.)

### 3.3 Confirm the SSM Agent is running and the instance registers

SSH into the instance once more (your own admin key, not CI) to check:
```bash
# Official Ubuntu AMIs ship the agent as a snap:
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service

# If it's not installed at all:
sudo snap install amazon-ssm-agent --classic
sudo snap start amazon-ssm-agent
```

From your own machine, confirm AWS sees it as a managed instance (can take 1–2 minutes after attaching the role):
```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
  --region "$REGION"
```
You must see one entry with `"PingStatus": "Online"` before continuing. If the list is empty, see Troubleshooting (§7) before moving on — nothing past this point will work until the instance shows up here.

### 3.4 Create the IAM user for GitHub Actions

```bash
aws iam create-user --user-name github-actions-deploy

cat > /tmp/github-actions-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ValidateCredentials",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "SendSSMCommand",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:$REGION:$ACCOUNT_ID:instance/$EC2_INSTANCE_ID",
        "arn:aws:ssm:$REGION::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "ReadSSMCommandResults",
      "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"],
      "Resource": "*"
    },
    {
      "Sid": "UploadDeployArtifacts",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET_NAME/releases/*"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name github-actions-deploy \
  --policy-name GitHubActionsDeployPolicy \
  --policy-document file:///tmp/github-actions-policy.json
```

This policy is scoped to exactly one instance, one S3 prefix, and one SSM document — this IAM user cannot touch any other EC2 instance, S3 bucket, or AWS service in your account.

Generate the access key (shown **once** — copy both values immediately):
```bash
aws iam create-access-key --user-name github-actions-deploy
```
Output looks like:
```json
{
    "AccessKey": {
        "UserName": "github-actions-deploy",
        "AccessKeyId": "AKIA...",
        "SecretAccessKey": "wJalrXUtnFEMI...",
        ...
    }
}
```
If you lose the `SecretAccessKey`, you can't retrieve it again — you'd delete that access key and create a new one.

### 3.5 Make the GHCR packages public (so EC2 can pull with no registry login)

Because there's no SSH session for the pipeline to deliver a short-lived registry token through anymore, the simplest and most robust option is to make the two GHCR packages public — they contain only the compiled app (no secrets, no `DATABASE_URL`, no credentials baked in), so there's no confidentiality concern here.

1. Trigger the pipeline once (push to `main`, or run it manually) so `build-and-push` creates the packages for the first time.
2. GitHub → your profile → **Packages** tab (or the repo's right sidebar → **Packages**) → open `replit_porject-api`.
3. **Package settings → Change visibility → Public**. Repeat for `replit_porject-web`.

If you'd rather keep them private, EC2 needs another way to authenticate to GHCR (e.g. a long-lived PAT stored in AWS Secrets Manager, read by the instance role) — not covered here since it adds infrastructure that isn't needed for a non-sensitive build artifact like this one.

---

## 4. GitHub Secrets and Variables

GitHub → repo → **Settings → Secrets and variables → Actions**.

**Secrets tab** (New repository secret):

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | `AccessKeyId` from step 3.4 |
| `AWS_SECRET_ACCESS_KEY` | `SecretAccessKey` from step 3.4 |

**Variables tab** (New repository variable):

| Name | Value |
|---|---|
| `AWS_REGION` | your `$REGION`, e.g. `us-east-1` |
| `EC2_INSTANCE_ID` | your `$EC2_INSTANCE_ID`, e.g. `i-0123456789abcdef0` |
| `EC2_APP_DIR` | `/home/ubuntu/Replit_porject` |
| `DEPLOY_S3_BUCKET` | your `$BUCKET_NAME` |
| `EC2_HOST` | your EC2 public IP or domain (still used for the post-deploy public smoke test) |
| `DEPLOY_BRANCH` | optional, defaults to `main` |

If you have leftover `EC2_SSH_KEY` / `EC2_KNOWN_HOSTS` secrets or `EC2_USER` / `EC2_SSH_PORT` variables from an earlier SSH-based setup, they're unused now and can be deleted.

---

## 5. First run and verification

1. Confirm everything in §3 and §4 is done, especially §3.3 (instance shows as `Online` in SSM) and §3.5 (packages public).
2. GitHub → repo → **Actions** tab → **Deploy portfolio to EC2** → **Run workflow**.
3. Watch the jobs: `gate → validate → build-and-push → deploy → smoke-test → report`.
4. Open the run's **Deployment summary** (job summary, bottom of the `report` job) — it shows the deployed commit, both image tags, and `Live at http://<EC2_HOST>/` if it succeeded.
5. Confirm from your own machine too:
   ```bash
   curl -I http://<EC2_HOST>/
   curl -i http://<EC2_HOST>/api/healthz
   ```

## 6. Rollback

Automatic: if `deploy` or `smoke-test` fails, the `rollback` job sends `./deploy/deploy.sh rollback` to the instance via the same SSM mechanism — no registry or S3 access needed, since it only flips Docker Compose back to the previous image tags already cached on the box.

Manual, from the AWS side (no SSH needed):
```bash
aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters commands='["cd /home/ubuntu/Replit_porject","chmod +x deploy/deploy.sh","./deploy/deploy.sh rollback"]' \
  --region "$REGION" \
  --query "Command.CommandId" --output text
```
Then check the result:
```bash
aws ssm get-command-invocation --command-id <id-from-above> --instance-id "$EC2_INSTANCE_ID" --region "$REGION"
```

Manual, the simplest way if you still have your own SSH access to the box: `ssh` in as usual and run `./deploy/deploy.sh rollback` directly — this never depended on the CI credential model.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `aws ssm describe-instance-information` returns an empty list | Instance role not attached, or SSM Agent not running | Re-check §3.2 and §3.3; also confirm the instance has outbound internet access (or VPC endpoints for `ssm`, `ssmmessages`, `ec2messages` if it's in a private subnet with no NAT) |
| `AccessDeniedException` on `ssm:SendCommand` in the workflow log | IAM user policy's resource ARNs don't match your actual region/account/instance ID | Re-check the ARNs in §3.4 character-for-character against `$REGION`, `$ACCOUNT_ID`, `$EC2_INSTANCE_ID` |
| SSM command status stays `InProgress` past the workflow's polling window | Instance under heavy load, or Docker pull is just slow (first pull with no layer cache) | Increase the `seq 1 30` retry count in `deploy.yml`'s `deploy` job, or just re-run once layers are cached |
| SSM command status `Failed` | The actual `deploy.sh pull-deploy` failed on the instance | The workflow log prints `StandardOutputContent`/`StandardErrorContent` directly — read that first, it's the real error (usually `docker compose pull` failing, e.g. because packages are still private — see §3.5) |
| `docker compose pull` fails with `pull access denied` on the instance | GHCR package visibility is still Private | Set it to Public (§3.5), or implement a private-registry credential path |
| `NoSuchBucket` / `AccessDenied` on `aws s3 cp` from the instance | Instance role missing the S3 read policy, or wrong bucket name in `DEPLOY_S3_BUCKET` | Re-check §3.2's inline policy and the `DEPLOY_S3_BUCKET` variable value |
| Workflow step "Validate deployment settings" fails immediately | A required secret/variable is missing | The error message names exactly which one — re-check §4 |

---

## 8. Security notes

- This IAM user's access keys are **long-lived** — they don't expire on their own. Rotate them periodically:
  ```bash
  aws iam create-access-key --user-name github-actions-deploy   # issue a new one
  # update AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in GitHub, confirm a deploy works, then:
  aws iam delete-access-key --user-name github-actions-deploy --access-key-id <OLD_KEY_ID>
  ```
- To fully revoke CI's AWS access at any time: `aws iam delete-access-key` (keeps the user, immediate effect) or `aws iam delete-user` (after removing its policy and keys).
- A stronger long-term option is **GitHub OIDC federation** (`aws-actions/configure-aws-credentials` with `role-to-assume`, no stored keys at all — GitHub and AWS exchange a short-lived token per run). It removes the "long-lived secret sitting in GitHub" risk entirely. This guide uses a plain IAM user because that's what was asked for; OIDC is a drop-in upgrade later if you want it — ask and this can be converted.
- The IAM user's policy is scoped to one instance ARN, one SSM document, and one S3 prefix — even if the access keys leaked, the blast radius is limited to sending shell commands to this one EC2 instance and writing to this one S3 prefix, not your whole AWS account.
