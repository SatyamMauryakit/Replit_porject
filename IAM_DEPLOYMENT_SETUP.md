# IAM + AWS Systems Manager Deployment Setup

This is the step-by-step guide for the credential model the CI/CD pipeline (`.github/workflows/deploy.yml`) actually uses: a dedicated **IAM user** authenticates GitHub Actions to AWS, and deployment runs over **AWS Systems Manager (SSM) Run Command** — there is no SSH key, no open port 22 needed for CI, no SSH host-key management, and **no S3 bucket or any other file-transfer mechanism**. EC2 keeps its own `git clone` of this repository and simply `git fetch` + `git checkout`s the exact deployed commit directly from GitHub — the repo is public, so this needs no credential on the server at all.

If you previously set up `EC2_SSH_KEY` / `EC2_KNOWN_HOSTS` secrets, or a `DEPLOY_S3_BUCKET` variable, for an earlier version of this pipeline, none of them are used anymore and can be deleted from GitHub.

---

## 0. Why this architecture

| | SSH-based | S3-based | This guide (IAM + SSM + git) |
|---|---|---|---|
| Credential in GitHub | A private SSH key | IAM user access keys | IAM user access keys |
| Port 22 needed for CI | Yes | No | No |
| How files reach EC2 | `rsync` over SSH | Private S3 bucket | `git fetch` from GitHub directly |
| Extra AWS infrastructure | None | S3 bucket + extra IAM policies | **None** — just the IAM user and the instance's own role |
| Revoking CI's access | Remove key from `authorized_keys` | Delete the IAM access key | Delete the IAM access key |

Two different AWS identities are involved and it's easy to conflate them:
- **The IAM user** (`github-actions-deploy`) — used by GitHub Actions itself to call AWS APIs (`ssm:SendCommand`). Lives in IAM, has access keys.
- **The EC2 instance role** — attached directly to your EC2 instance so the SSM Agent running on it can register with AWS Systems Manager and receive commands. This is a role, not a user, has no access keys, and EC2 assumes it automatically.

Both are required — the IAM user alone can't make SSM Run Command work if the instance itself has no role allowing it to be managed. Neither one touches S3, a registry credential, or anything else: this is the leanest version of this pipeline.

---

## 1. Architecture

```
GitHub Actions workflow
   │
   │  aws ssm send-command
   │  "git fetch origin && git checkout <exact commit sha> && deploy/deploy.sh pull-deploy"
   │  (using IAM user access keys — this is the ONLY AWS permission it needs)
   ▼
EC2 instance (SSM Agent + instance role, already has its own git clone of this repo)
   │
   │  git fetch + checkout pulls the exact commit straight from github.com
   │  (public repo — no token, no deploy key, nothing stored on the server)
   ▼
docker compose pull (images from GHCR, public) + up
```

No inbound connection from GitHub to EC2 at all, and no AWS storage service involved — the EC2 instance's SSM Agent makes an outbound connection to AWS Systems Manager and polls for commands; `git fetch` is a plain outbound HTTPS call to github.com, same as `git pull` on any machine.

---

## 2. Prerequisites

- AWS CLI installed and configured on **your own machine** with sufficiently privileged credentials (your normal admin/account user — not the IAM user you're about to create, which deliberately won't have permission to create other IAM resources).
- Your AWS account ID and region:
  ```bash
  aws sts get-caller-identity --query Account --output text
  ```

Set these as shell variables now — every command below reuses them:
```bash
export REGION="us-east-1"                      # your EC2's region
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

---

## 3. Setting up the EC2 instance

Pick whichever matches your situation.

### 3A. Fresh EC2 instance (recommended — a clean slate for this pipeline)

1. **Launch the instance.** Follow `AWS_DEPLOYMENT.md` §1 (AMI, instance size, storage, security group) and §2 (install Docker, Nginx, Certbot). Skip nothing there — this pipeline only replaces *how deploys happen*, not the base server setup.

2. **Attach the IAM instance role** (created in §3.2 below) either at launch time:
   ```bash
   aws ec2 run-instances \
     --iam-instance-profile Name=Replit-Porject-EC2-SSM-Profile \
     ... # your other existing run-instances flags (AMI, instance type, security group, key pair)
   ```
   or to an already-running instance, no restart needed:
   ```bash
   aws ec2 associate-iam-instance-profile \
     --instance-id <EC2_INSTANCE_ID> \
     --iam-instance-profile Name=Replit-Porject-EC2-SSM-Profile
   ```
   (Console equivalent: EC2 → Instances → select instance → **Actions → Security → Modify IAM role**.)

3. **Install git and clone the repo** (SSH in once with your own admin key — this is the last time you'll need to):
   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/SatyamMauryakit/Replit_porject.git ~/Replit_porject
   cd ~/Replit_porject
   chmod +x deploy/deploy.sh
   ```

4. **Install the host Nginx config** — `AWS_DEPLOYMENT.md` §4.

5. **Prove the box works once, manually**, before handing it to CI:
   ```bash
   ./deploy/deploy.sh deploy     # builds from source locally, starts containers, health-checks
   curl -I http://127.0.0.1:18080/
   ```

### 3B. Adapting an EC2 instance that already has this app on it (not a git clone yet)

If `/home/ubuntu/Replit_porject` already exists but wasn't created with `git clone` (e.g. it was `rsync`'d there), convert it in place without losing the release-tracking state:
```bash
cd ~
mv Replit_porject Replit_porject.bak
git clone https://github.com/SatyamMauryakit/Replit_porject.git Replit_porject
mv Replit_porject.bak/.deploy-state Replit_porject/.deploy-state 2>/dev/null || true
cd Replit_porject
chmod +x deploy/deploy.sh
./deploy/deploy.sh status        # confirm containers are still fine
rm -rf ~/Replit_porject.bak      # once you're satisfied
```
Then do steps 2 (attach IAM role) from §3A above.

---

## 4. Create the EC2 instance role (lets SSM manage the box)

This is the same regardless of 3A or 3B.

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

That's the entire role — just the one AWS-managed policy (`AmazonSSMManagedInstanceCore`). No inline policy, no S3 permission, nothing custom: the instance doesn't need to reach any other AWS service for this pipeline to work.

Wait about 10 seconds for IAM to propagate, then attach it to your instance (see §3A step 2 if you haven't already).

### 4.1 Confirm the SSM Agent is running and the instance registers

SSH into the instance once more (your own admin key) to check:
```bash
# Official Ubuntu AMIs ship the agent as a snap:
sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service

# If it's not installed at all:
sudo snap install amazon-ssm-agent --classic
sudo snap start amazon-ssm-agent
```

From your own machine, confirm AWS sees it as a managed instance (can take 1–2 minutes after attaching the role):
```bash
export EC2_INSTANCE_ID="i-0123456789abcdef0"    # your actual instance ID

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
  --region "$REGION"
```
You must see one entry with `"PingStatus": "Online"` before continuing. If the list is empty, see Troubleshooting (§7) — nothing past this point works until the instance shows up here.

---

## 5. Create the IAM user for GitHub Actions

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
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name github-actions-deploy \
  --policy-name GitHubActionsDeployPolicy \
  --policy-document file:///tmp/github-actions-policy.json
```

This is the entire policy — four actions, scoped to exactly one instance and one SSM document. No S3, no EC2 management, no IAM, nothing else in your account. This IAM user can do exactly one thing: tell this one instance to run a shell command, and read the result back.

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
If you lose the `SecretAccessKey`, you can't retrieve it again — delete that access key and create a new one.

---

## 6. Make the GHCR packages public (so EC2 can pull with no registry login)

Since there's no SSH session and no S3 object for the pipeline to deliver a registry credential through, the simplest and most robust option is to make the two GHCR packages public — they contain only the compiled app (no secrets, no `DATABASE_URL`, no credentials baked in), so there's no confidentiality concern here.

1. Trigger the pipeline once (push to `main`, or run it manually) so `build-and-push` creates the packages for the first time.
2. GitHub → your profile → **Packages** tab (or the repo's right sidebar → **Packages**) → open `replit_porject-api`.
3. **Package settings → Change visibility → Public**. Repeat for `replit_porject-web`.

If you'd rather keep them private, EC2 needs another way to authenticate to GHCR (e.g. a long-lived PAT stored in AWS Secrets Manager, read by the instance role) — not covered here since it adds infrastructure that isn't needed for a non-sensitive build artifact like this one.

---

## 7. GitHub Secrets and Variables

GitHub → repo → **Settings → Secrets and variables → Actions**.

**Secrets tab** (New repository secret):

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | `AccessKeyId` from §5 |
| `AWS_SECRET_ACCESS_KEY` | `SecretAccessKey` from §5 |

**Variables tab** (New repository variable):

| Name | Value |
|---|---|
| `AWS_REGION` | your `$REGION`, e.g. `us-east-1` |
| `EC2_INSTANCE_ID` | your `$EC2_INSTANCE_ID`, e.g. `i-0123456789abcdef0` |
| `EC2_APP_DIR` | `/home/ubuntu/Replit_porject` |
| `EC2_HOST` | your EC2 public IP or domain (used for the post-deploy public smoke test) |
| `DEPLOY_BRANCH` | optional, defaults to `main` |

Nothing else — no `DEPLOY_S3_BUCKET`, no SSH-related entries. If you have leftover ones from an earlier setup, delete them.

---

## 8. First run and verification

1. Confirm §3, §4, §5, §6 are all done, especially §4.1 (instance shows `Online` in SSM) and §6 (packages public).
2. GitHub → repo → **Actions** tab → **Deploy portfolio to EC2** → **Run workflow**.
3. Watch the jobs: `gate → validate → build-and-push → deploy → smoke-test → report`.
4. Open the run's **Deployment summary** (bottom of the `report` job) — it shows the deployed commit, both image tags, and `Live at http://<EC2_HOST>/` if it succeeded.
5. Confirm from your own machine too:
   ```bash
   curl -I http://<EC2_HOST>/
   curl -i http://<EC2_HOST>/api/healthz
   ```

## 9. Rollback

Automatic: if `deploy` or `smoke-test` fails, the `rollback` job sends `./deploy/deploy.sh rollback` to the instance via the same SSM mechanism — no git fetch, no registry access needed, since it only flips Docker Compose back to the previous image tags already cached on the box.

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

Manual, the simplest way if you still have your own SSH access to the box: `ssh` in as usual and run `./deploy/deploy.sh rollback` directly.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `aws ssm describe-instance-information` returns an empty list | Instance role not attached, or SSM Agent not running | Re-check §4 and §4.1; confirm the instance has outbound internet access (or VPC endpoints for `ssm`, `ssmmessages`, `ec2messages` if it's in a private subnet with no NAT) |
| `AccessDeniedException` on `ssm:SendCommand` in the workflow log | IAM user policy's resource ARNs don't match your actual region/account/instance ID | Re-check the ARNs in §5 character-for-character against `$REGION`, `$ACCOUNT_ID`, `$EC2_INSTANCE_ID` |
| SSM command fails with "not a git clone yet" | `$EC2_APP_DIR` exists but isn't a git repository | Follow §3B to convert it in place |
| `git fetch origin` fails on the instance | No outbound internet access, or GitHub is rate-limiting/blocking that IP | Confirm `curl -I https://github.com` works from the instance; unauthenticated GitHub requests are rate-limited per IP, rarely an issue for one `git fetch` per deploy |
| SSM command status stays `InProgress` past the workflow's polling window | Instance under heavy load, or Docker pull is just slow (first pull with no layer cache) | Increase the `seq 1 30` retry count in `deploy.yml`'s `deploy` job, or just re-run once layers are cached |
| SSM command status `Failed` | The actual `deploy.sh pull-deploy` failed on the instance | The workflow log prints `StandardOutputContent`/`StandardErrorContent` directly — read that first, it's the real error (usually `docker compose pull` failing, e.g. because packages are still private — see §6) |
| `docker compose pull` fails with `pull access denied` on the instance | GHCR package visibility is still Private | Set it to Public (§6), or implement a private-registry credential path |
| Workflow step "Validate deployment settings" fails immediately | A required secret/variable is missing | The error message names exactly which one — re-check §7 |

---

## 11. Security notes

- This IAM user's access keys are **long-lived** — they don't expire on their own. Rotate them periodically:
  ```bash
  aws iam create-access-key --user-name github-actions-deploy   # issue a new one
  # update AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in GitHub, confirm a deploy works, then:
  aws iam delete-access-key --user-name github-actions-deploy --access-key-id <OLD_KEY_ID>
  ```
- To fully revoke CI's AWS access at any time: `aws iam delete-access-key` (keeps the user, immediate effect) or `aws iam delete-user` (after removing its policy and keys).
- A stronger long-term option is **GitHub OIDC federation** (`aws-actions/configure-aws-credentials` with `role-to-assume`, no stored keys at all — GitHub and AWS exchange a short-lived token per run). It removes the "long-lived secret sitting in GitHub" risk entirely. This guide uses a plain IAM user because that's what was asked for; OIDC is a drop-in upgrade later if you want it.
- The IAM user's policy is scoped to exactly one instance ARN and one SSM document — even if the access keys leaked, the blast radius is limited to sending shell commands to this one EC2 instance, not your whole AWS account.
- The EC2 instance role has exactly one AWS-managed policy (`AmazonSSMManagedInstanceCore`) — it cannot read or write anything else in your AWS account either.
