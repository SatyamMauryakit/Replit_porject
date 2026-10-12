# IAM + AWS Systems Manager Deployment Setup

This is the step-by-step guide for the credential model the CI/CD pipeline (`.github/workflows/deploy.yml`) actually uses: a dedicated **IAM user** authenticates GitHub Actions to AWS, deployment runs over **AWS Systems Manager (SSM) Run Command** — no SSH key, no open port 22, no SSH host-key management, no S3 bucket — and **the pipeline provisions its own EC2 instance the first time it runs**, then reuses that same instance on every run after.

If you previously set up `EC2_SSH_KEY` / `EC2_KNOWN_HOSTS` secrets, a `DEPLOY_S3_BUCKET` variable, or manually launched and configured an EC2 instance for an earlier version of this pipeline, none of that manual server setup is needed anymore — this guide replaces it.

---

## 0. Why this architecture

| | SSH-based | S3-based | Pre-existing instance (IAM + SSM) | This guide (+ auto-provisioning) |
|---|---|---|---|---|
| Credential in GitHub | A private SSH key | IAM user access keys | IAM user access keys | IAM user access keys |
| Port 22 needed for CI | Yes | No | No | No |
| How files reach EC2 | `rsync` over SSH | Private S3 bucket | `git fetch` from GitHub | `git fetch` from GitHub |
| You launch the EC2 instance yourself | Yes | Yes | Yes | **No — the pipeline does it, once** |
| IAM footprint | SSH key only | S3 + SSM policies | SSM on one known instance | SSM **and** EC2 launch/network permissions |

Two different AWS identities are involved and it's easy to conflate them:
- **The IAM user** (`github-actions-deploy`) — used by GitHub Actions itself to call AWS APIs. Lives in IAM, has access keys. You create this once, by hand.
- **The EC2 instance role** — attached to whichever EC2 instance the pipeline is running, so the SSM Agent on it can register with Systems Manager and receive commands. This is a role, not a user, has no access keys. You create this once, by hand; the pipeline attaches it to new instances automatically at launch.

**The honest trade-off of auto-provisioning:** letting CI create infrastructure (not just use infrastructure you already made) necessarily means a broader IAM footprint. `ec2:RunInstances` in particular cannot be scoped down to "only this one future instance" the way `ssm:SendCommand` can be scoped to an existing one — AWS's own permission model requires broad resource access for that action. §5 scopes everything that *can* be scoped (via tag conditions) and is explicit about the one thing that can't be. If you'd rather keep the tighter, pre-existing-instance-only policy from before, that's a smaller and simpler setup — say so and this can be reverted.

---

## 1. Architecture

```
First run ever:
  GitHub Actions "provision" job
     │  aws ec2 describe-instances (tag:Name=EC2_NAME_TAG) → nothing found
     │  aws ec2 create-security-group + authorize-ingress (80, 443 only — no port 22)
     │  aws ssm get-parameters → latest Ubuntu AMI ID
     │  aws ec2 run-instances (AMI, instance role attached at launch,
     │                         deploy/bootstrap-ec2.sh as --user-data)
     │  aws ec2 allocate-address + associate-address (stable public IP)
     ▼
  New EC2 instance boots, cloud-init runs deploy/bootstrap-ec2.sh:
  installs Docker + Nginx, clones this repo, configures the Nginx proxy

Every run (including the first, right after provisioning):
  GitHub Actions "provision" job
     │  aws ec2 describe-instances (tag:Name=EC2_NAME_TAG) → found, reuse it
     │  wait for running + SSM-online + cloud-init finished
     ▼
  GitHub Actions "deploy" job
     │  aws ssm send-command:
     │  "git fetch origin && git checkout <exact commit sha> && deploy/deploy.sh pull-deploy"
     ▼
  EC2 instance: git fetch + checkout (public repo, no credential needed)
     ▼
  docker compose pull (images from GHCR, public) + up
```

No inbound connection from GitHub to EC2 at all. No SSH port open — not even for you: use `aws ssm start-session --target <instance-id>` for an interactive shell any time, which needs nothing but your own AWS CLI credentials and the same SSM Agent the pipeline already depends on.

---

## 2. Prerequisites

- AWS CLI installed and configured on **your own machine** with sufficiently privileged credentials (your normal admin/account user — not the IAM user you're about to create, which won't have permission to create other IAM resources).
- A **default VPC** in your target region (every AWS account has one unless it was deliberately deleted) — the provisioning job launches into it. Check with:
  ```bash
  aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region ap-south-1
  ```
  If that returns nothing, create a default VPC (`aws ec2 create-default-vpc`) or launch into a specific VPC/subnet of your own — the latter needs a small edit to the `provision` job in `deploy.yml` (set `--subnet-id` explicitly) since this guide assumes the default VPC.
- Your AWS account ID and region:
  ```bash
  aws sts get-caller-identity --query Account --output text
  ```

Set these as shell variables now — every command below reuses them:
```bash
export REGION="ap-south-1"                      # your target region
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

---

## 3. Create the EC2 instance role (lets SSM manage whatever instance exists)

This is created **once**, independent of any specific instance — the pipeline attaches it by name to whichever instance it launches.

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

aws iam create-instance-profile --instance-profile-name Replit-Porject-EC2-SSM-Profile
aws iam add-role-to-instance-profile \
  --instance-profile-name Replit-Porject-EC2-SSM-Profile \
  --role-name Replit-Porject-EC2-SSM-Role
```

Just the one AWS-managed policy (`AmazonSSMManagedInstanceCore`) — no inline policy, no S3, nothing custom. Wait about 10 seconds for IAM to propagate before the pipeline's first run.

This profile name (`Replit-Porject-EC2-SSM-Profile`) is the default the pipeline looks for (`EC2_INSTANCE_ROLE_PROFILE` variable) — only set that variable if you named it differently.

---

## 4. Create the IAM user for GitHub Actions

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
      "Sid": "DiscoverExistingInstance",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      "Resource": "*"
    },
    {
      "Sid": "ManageTaggedInstanceOnly",
      "Effect": "Allow",
      "Action": "ec2:StartInstances",
      "Resource": "arn:aws:ec2:$REGION:$ACCOUNT_ID:instance/*",
      "Condition": {
        "StringEquals": { "ec2:ResourceTag/Name": "replit-porject" }
      }
    },
    {
      "Sid": "SendSSMCommandToTaggedInstance",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ec2:$REGION:$ACCOUNT_ID:instance/*",
      "Condition": {
        "StringEquals": { "ec2:ResourceTag/Name": "replit-porject" }
      }
    },
    {
      "Sid": "SendSSMCommandDocument",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:$REGION::document/AWS-RunShellScript"
    },
    {
      "Sid": "ReadSSMCommandResults",
      "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"],
      "Resource": "*"
    },
    {
      "Sid": "LookUpLatestUbuntuAmi",
      "Effect": "Allow",
      "Action": "ssm:GetParameters",
      "Resource": "arn:aws:ssm:$REGION::parameter/aws/service/canonical/*"
    },
    {
      "Sid": "LaunchTaggedInstanceOnly",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestTag/Name": "replit-porject" }
      }
    },
    {
      "Sid": "NetworkAndSecurityGroupSetup",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVpcs",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElasticIpForStablePublicAddress",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAddresses",
        "ec2:AllocateAddress",
        "ec2:AssociateAddress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassInstanceRoleAtLaunch",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::$ACCOUNT_ID:role/Replit-Porject-EC2-SSM-Role"
    },
    {
      "Sid": "VerifyInstanceProfileExistsBeforeLaunch",
      "Effect": "Allow",
      "Action": "iam:GetInstanceProfile",
      "Resource": "arn:aws:iam::$ACCOUNT_ID:instance-profile/Replit-Porject-EC2-SSM-Profile"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name github-actions-deploy \
  --policy-name GitHubActionsDeployPolicy \
  --policy-document file:///tmp/github-actions-policy.json
```

**What's actually scoped vs. not, honestly:**
- `ec2:StartInstances` and `ssm:SendCommand` on an instance are restricted to instances tagged `Name=replit-porject` — this IAM user cannot start or send commands to any *other* EC2 instance in your account, even though the resource ARN is a wildcard (tag-based conditions, not ARN-based, since the instance ID isn't known in advance).
- `ec2:RunInstances` requires launching with that same `Name=replit-porject` tag (`aws:RequestTag` condition) — it can't be used to quietly launch an untagged or differently-named instance. It does need `Resource: "*"` — AWS's `RunInstances` resource-level permission model spans several sub-resource types (AMI, subnet, security group, network interface, volume) and doesn't support narrowing all of those to a not-yet-existing instance.
- `ec2:DescribeInstances`/`DescribeInstanceStatus`/`DescribeVpcs`/`DescribeSecurityGroups`/`DescribeAddresses` are read-only, account-wide by AWS's design (Describe* actions don't support resource-level permissions) — this user can *see* your other EC2 resources exist, but can't change, stop, terminate, or read data from them.
- `iam:PassRole` and `iam:GetInstanceProfile` are both scoped to exactly the one instance role/profile created in §3 — this user cannot pass or inspect any other role in your account. Note: this user cannot *create* roles or instance profiles (no `iam:CreateRole`, no `iam:AttachRolePolicy`) — letting a CI credential create and attach its own IAM roles is a well-known privilege-escalation pattern, so that step stays manual, done once by you with your own admin credentials (§3).

If you'd rather not grant `ec2:RunInstances`/security-group/Elastic-IP permissions at all, don't use the auto-provisioning path — go back to manually launching the instance once (the older, simpler, more tightly-scoped version of this guide) and just keep the `EC2_INSTANCE_ID` variable pinned; ask and this can be reverted.

Generate the access key (shown **once** — copy both values immediately):
```bash
aws iam create-access-key --user-name github-actions-deploy
```
If you lose the `SecretAccessKey`, you can't retrieve it again — delete that access key and create a new one.

---

## 5. Make the GHCR packages public (so EC2 can pull with no registry login)

There's no SSH session and no S3 object for the pipeline to deliver a registry credential through, so the simplest option is to make the two GHCR packages public — they contain only the compiled app, no secrets.

1. Trigger the pipeline once so `build-and-push` creates the packages for the first time.
2. GitHub → your profile (or the repo's right sidebar) → **Packages** → open `replit_porject-api`.
3. **Package settings → Change visibility → Public**. Repeat for `replit_porject-web`.

---

## 6. GitHub Secrets and Variables

GitHub → repo → **Settings → Secrets and variables → Actions**.

**Secrets tab** (New repository secret):

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | `AccessKeyId` from §4 |
| `AWS_SECRET_ACCESS_KEY` | `SecretAccessKey` from §4 |

**Variables tab** (New repository variable):

| Name | Required | Default if unset | Purpose |
|---|---|---|---|
| `AWS_REGION` | Yes | — | Where to provision/look for the instance, e.g. `ap-south-1` |
| `EC2_NAME_TAG` | No | `replit-porject` | The tag the pipeline searches for and creates the instance with. Must match the tag condition in the §4 policy if you change it. |
| `EC2_INSTANCE_TYPE` | No | `t3.micro` | Only used when creating a new instance. No build happens on EC2 anymore (images are pulled pre-built), so this can stay small. |
| `EC2_INSTANCE_ROLE_PROFILE` | No | `Replit-Porject-EC2-SSM-Profile` | Must match the instance profile name from §3. |
| `EC2_APP_DIR` | No | `/home/ubuntu/Replit_porject` | Must match the path `deploy/bootstrap-ec2.sh` clones into. |
| `DEPLOY_BRANCH` | No | `main` | Which branch triggers an actual deploy. |

Nothing else — no `EC2_INSTANCE_ID`, no `EC2_HOST` (the `provision` job discovers/creates the instance and its IP dynamically every run), no `DEPLOY_S3_BUCKET`, no SSH-related entries. Delete any of those left over from an earlier setup.

---

## 7. First run and verification

1. Confirm §3, §4, §5 are done.
2. GitHub → repo → **Actions** → **Deploy portfolio to EC2** → **Run workflow**.
3. Watch the jobs: `gate` and `provision`/`validate` run in parallel, then `build-and-push` → `deploy` → `smoke-test` → `report`.
4. The **first** run's `provision` job takes noticeably longer than later ones — it's creating the security group, launching the instance, and waiting for `deploy/bootstrap-ec2.sh` to finish installing Docker/Nginx/git (budget 3–6 minutes). Every run after that reuses the same instance and skips straight to the readiness checks.
5. Open the run's **Deployment summary** — it shows the instance ID, deployed commit, both image tags, and `Live at http://<public-ip>/` if it succeeded. The public IP is an Elastic IP, so it stays the same across every future run, reboot, or instance replacement.
6. Confirm from your own machine too, using the IP from the summary:
   ```bash
   curl -I http://<public-ip>/
   curl -i http://<public-ip>/api/healthz
   ```

To get a shell on the instance at any point (debugging, checking logs) — no SSH key or open port needed:
```bash
aws ssm start-session --target <instance-id> --region "$REGION"
```

---

## 8. Rollback

Automatic: if `deploy` or `smoke-test` fails, the `rollback` job sends `./deploy/deploy.sh rollback` to the instance via SSM — no git fetch, no registry access needed, since it only flips Docker Compose back to the previous image tags already cached on the box.

Manual, from the AWS side:
```bash
instance_id=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=replit-porject" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION")

aws ssm send-command \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --parameters commands='["cd /home/ubuntu/Replit_porject","chmod +x deploy/deploy.sh","./deploy/deploy.sh rollback"]' \
  --region "$REGION" \
  --query "Command.CommandId" --output text
```

Manual, the simplest way: `aws ssm start-session --target "$instance_id"` and run `./deploy/deploy.sh rollback` directly in the session.

---

## 9. Starting over / recreating the instance

Because the pipeline finds the instance purely by its `Name` tag, you can force a completely fresh instance at any time — just remove the old one and the *next* pipeline run creates a new one automatically:
```bash
instance_id=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=replit-porject" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION")
aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION"
```
The Elastic IP and security group are left in place and get reattached/reused automatically — your public IP doesn't change even across a full instance recreation.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `provision` job fails with "No default VPC found" | Account/region has no default VPC | Create one (`aws ec2 create-default-vpc --region $REGION`) or edit the `provision` job to use an explicit `--subnet-id` |
| `AccessDeniedException` on `ec2:RunInstances` | Policy not applied, or the tag-specification on launch doesn't match the `aws:RequestTag/Name` condition | Re-check §4's policy is attached (`aws iam get-user-policy --user-name github-actions-deploy --policy-name GitHubActionsDeployPolicy`); confirm `EC2_NAME_TAG` (if you changed it) matches the condition value in the policy |
| `AccessDeniedException` mentioning `iam:PassRole` | `PassInstanceRoleAtLaunch` statement missing or ARN mismatch | Confirm the role ARN in that statement matches `Replit-Porject-EC2-SSM-Role` exactly, including account ID |
| New instance created but never shows SSM `Online` | `EC2_INSTANCE_ROLE_PROFILE` name doesn't match an actual instance profile, or §3 wasn't completed before the first run | Re-check §3; confirm with `aws iam get-instance-profile --instance-profile-name Replit-Porject-EC2-SSM-Profile` |
| Bootstrap step fails / times out waiting for `cloud-init status --wait` | `deploy/bootstrap-ec2.sh` hit an error (apt failure, network issue) | `aws ssm start-session --target <instance-id>`, then `cat /var/log/replit-porject-bootstrap.log` to see exactly where it stopped |
| `git fetch origin` fails on the instance | No outbound internet access, or GitHub rate-limiting | Confirm `curl -I https://github.com` works from the instance over `ssm start-session` |
| SSM command status `Failed` | `deploy.sh pull-deploy` failed on the instance | The workflow log prints `StandardOutputContent`/`StandardErrorContent` directly — usually `docker compose pull` failing because packages are still private (see §5) |
| `docker compose pull` fails with `pull access denied` | GHCR package visibility is still Private | Set it to Public (§5) |
| Public IP in the summary doesn't match what you expect | A second Elastic IP got allocated somehow, or an old one is tagged | `aws ec2 describe-addresses --filters "Name=tag:Name,Values=replit-porject" --region $REGION` — there should be exactly one; release any duplicates with `aws ec2 release-address` |
| Workflow step "Validate provisioning/deployment settings" fails immediately | A required secret/variable is missing | The error message names exactly which one — re-check §6 |

---

## 11. Security notes

- This IAM user's access keys are **long-lived** — rotate them periodically:
  ```bash
  aws iam create-access-key --user-name github-actions-deploy
  # update the GitHub secrets, confirm a deploy works, then:
  aws iam delete-access-key --user-name github-actions-deploy --access-key-id <OLD_KEY_ID>
  ```
- To fully revoke CI's AWS access: `aws iam delete-access-key` (immediate, keeps the user) or `aws iam delete-user` (after removing its policy and keys).
- A stronger long-term option is **GitHub OIDC federation** (`aws-actions/configure-aws-credentials` with `role-to-assume`, no stored keys at all). This guide uses a plain IAM user because that's what was asked for; OIDC is a drop-in upgrade later.
- As covered in §4: the write actions that matter (`RunInstances`, `StartInstances`, `SendCommand`) are all constrained by the `Name=replit-porject` tag, except `RunInstances` itself which needs broad resource scope by AWS's own design (mitigated by the `aws:RequestTag` condition). The read-only Describe actions are account-wide by AWS's design and can't be narrowed further.
- The EC2 instance role has exactly one AWS-managed policy (`AmazonSSMManagedInstanceCore`) — it cannot read or write anything else in your AWS account.
- The security group the pipeline creates allows inbound 80/443 from anywhere and **nothing else** — no port 22 at all. All administrative access (yours and the pipeline's) goes through SSM, not SSH.
