# AWS EC2 Deployment Guide — Developer Portfolio

Step-by-step guide to deploy this repository (frontend + API, via Docker Compose) on a fresh AWS EC2 instance. Every command is copy-pasteable. Run EC2 commands over SSH on the instance unless noted otherwise.

Repository: `SatyamMauryakit/Replit_porject`

---

## 0. Architecture (what you're building)

```
Internet
   │  :80 / :443
   ▼
Host Nginx (on EC2, outside Docker)
   │  proxies to 127.0.0.1:18080
   ▼
Docker Compose "web" container (Nginx, SPA + /api/* proxy)
   │  proxies /api/* to api:5000 (internal Docker network only)
   ▼
Docker Compose "api" container (Express)
```

- Only host Nginx is exposed publicly (ports 80/443).
- The `web` container is bound to `127.0.0.1:18080` only — not reachable from the internet directly.
- The `api` container is never exposed outside the Docker network.

---

## 1. Launch the EC2 instance

1. AWS Console → EC2 → **Launch instance**.
2. AMI: **Ubuntu Server 22.04 LTS** (or 24.04 LTS).
3. Instance type: minimum **t3.small** (2 GB RAM). `t2.micro`/`t3.micro` (1 GB RAM) frequently gets OOM-killed during `pnpm install` / the Vite build step — avoid it, or add swap (step 2.4).
4. Key pair: create or select one you have the `.pem` for.
5. Storage: at least **16 GB** (default 8 GB can fill up with Docker build layers).
6. **Security group** — create/select one with these inbound rules:

| Type  | Protocol | Port | Source                          |
|-------|----------|------|----------------------------------|
| SSH   | TCP      | 22   | Your IP only (not `0.0.0.0/0`)  |
| HTTP  | TCP      | 80   | `0.0.0.0/0`                      |
| HTTPS | TCP      | 443  | `0.0.0.0/0`                      |

Do **not** open ports 5000 or 18080 publicly — they're internal only.

7. (Recommended) Allocate and associate an **Elastic IP** so the public IP doesn't change on reboot: EC2 → Elastic IPs → Allocate → Associate with your instance.

---

## 2. Connect and prepare the instance

### 2.1 SSH in
```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

### 2.2 Update the OS
```bash
sudo apt-get update
sudo apt-get upgrade -y
```

### 2.3 Install Docker, Nginx, and Certbot
```bash
sudo apt-get install -y ca-certificates curl gnupg nginx certbot python3-certbot-nginx

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/ubuntu' \
  "Suites: $(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" \
  'Components: stable' \
  "Architectures: $(dpkg --print-architecture)" \
  'Signed-By: /etc/apt/keyrings/docker.gpg' \
  | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo systemctl enable --now nginx
```

### 2.4 (Only if using 1–2 GB RAM instances) Add swap
Prevents the Docker build from being OOM-killed on small instances:
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### 2.5 Run Docker without `sudo` (optional but convenient)
```bash
sudo usermod -aG docker "$USER"
exit
```
Then reconnect (`ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>`) — group changes require a fresh session.

### 2.6 Remove the default Nginx site (avoids a "Welcome to nginx" page masking your app)
```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

---

## 3. Get the code onto the instance

Pick **one** of the two methods below.

### Option A — `git clone` (simplest)
```bash
mkdir -p ~/developer-portfolio
cd ~/developer-portfolio
git clone https://github.com/SatyamMauryakit/Replit_porject.git .
```

### Option B — copy from your machine with `rsync`/`scp`
From your local machine (not the EC2 box):
```bash
rsync -avz --exclude '.git' --exclude 'node_modules' --exclude '**/dist' \
  -e "ssh -i your-key.pem" \
  ./ ubuntu@<EC2_PUBLIC_IP>:~/developer-portfolio/
```

---

## 4. Configure host Nginx

### 4.1 Edit the virtual host file
On the EC2 instance:
```bash
cd ~/developer-portfolio
nano deploy/nginx/developer-portfolio.conf
```
Replace `server_name your-domain.example;` with your real domain (or the server's public IP/`_` if you don't have a domain yet).

### 4.2 Install the config
```bash
sudo install -d -o root -g root -m 0755 /etc/nginx/snippets
sudo install -o root -g root -m 0644 \
  deploy/nginx/developer-portfolio-upstream.conf \
  /etc/nginx/snippets/developer-portfolio-upstream.conf
sudo install -o root -g root -m 0644 \
  deploy/nginx/developer-portfolio.conf \
  /etc/nginx/sites-available/developer-portfolio
sudo ln -sf /etc/nginx/sites-available/developer-portfolio /etc/nginx/sites-enabled/developer-portfolio

sudo nginx -t
sudo systemctl reload nginx
```

`nginx -t` must print `syntax is ok` / `test is successful` before continuing — fix any error it reports before moving on.

---

## 5. Build and start the app with Docker Compose

```bash
cd ~/developer-portfolio
chmod +x deploy/deploy.sh
./deploy/deploy.sh deploy
```

This single command runs `docker compose up --build --detach --remove-orphans --wait`, then checks:
- `http://127.0.0.1:18080/` (frontend)
- `http://127.0.0.1:18080/api/healthz` (API, proxied)

It prints `Deployment is healthy.` on success.

If you'd rather run it manually instead of via the script:
```bash
docker compose up --build -d --wait
docker compose ps
curl -i http://127.0.0.1:18080/
curl -i http://127.0.0.1:18080/api/healthz
```

---

## 6. Verify it's reachable from the internet

From **your own machine** (not the EC2 box):
```bash
curl -I http://<EC2_PUBLIC_IP_OR_DOMAIN>/
curl -I http://<EC2_PUBLIC_IP_OR_DOMAIN>/api/healthz
```
Both should return `HTTP/1.1 200 OK`. If they time out or refuse the connection, see the Troubleshooting section below — it's a network path issue, not a Docker/app issue.

---

## 7. Enable HTTPS (only if you have a real domain pointed at the instance)

Point your domain's DNS `A` record at the EC2 public IP (or Elastic IP) first, then:
```bash
sudo certbot --nginx -d your-real-domain.example --redirect
sudo certbot renew --dry-run
```
Certbot auto-renews via a systemd timer; `renew --dry-run` just confirms it's wired up correctly.

---

## 8. Day-2 operations (routine commands)

Run these from `~/developer-portfolio` on the EC2 instance:

```bash
./deploy/deploy.sh status          # container status
./deploy/deploy.sh logs            # recent logs, all services
./deploy/deploy.sh logs web        # logs for one service (web or api)
./deploy/deploy.sh health          # local health checks
./deploy/deploy.sh restart         # restart without rebuilding
./deploy/deploy.sh down            # stop containers
./deploy/deploy.sh deploy          # pull latest code change + rebuild + restart
```

### Deploying a new code change
```bash
cd ~/developer-portfolio
git pull origin main          # if using git clone
./deploy/deploy.sh deploy     # rebuilds images and restarts with --wait health check
```

Equivalent raw `docker compose` commands:
```bash
docker compose up --build -d --wait
docker compose ps
docker compose logs --tail=100
docker compose down
```

---

## 9. Automated CI/CD via GitHub Actions

`.github/workflows/deploy.yml` is a multistage pipeline that runs automatically on every push to the deploy branch (`main` by default), and can also be triggered manually.

### 9.0 Architecture

```
push to main
     │
     ▼
┌─────────┐   ┌──────────┐   ┌──────────────────┐   ┌─────────────┐   ┌──────────┐
│  gate   │──▶│ validate │──▶│  build-and-push   │──▶│   deploy    │──▶│ smoke-   │
│(branch  │   │ (reuses  │   │ (build api+web,   │   │ (AWS SSM,   │   │ test     │
│ check)  │   │ ci.yml)  │   │  push to GHCR,    │   │  no SSH —   │   │ (curl    │
└─────────┘   └──────────┘   │  tag = commit SHA)│   │  see below) │   │ public   │
                              └──────────────────┘   └─────────────┘   │ IP :80)  │
                                                                        └────┬─────┘
                                                                              │ fails
                                                                              ▼
                                                                      ┌──────────────┐
                                                                      │  rollback     │
                                                                      │ (revert EC2   │
                                                                      │  to previous  │
                                                                      │  image tag)   │
                                                                      └──────────────┘
                                   all stages ──────────────────────▶ report (summary)
```

**Why build-once-push-to-registry instead of building on EC2:**
- CI runners have far more CPU/RAM than a small EC2 instance — no more OOM risk during the build.
- The exact artifact that passed lint/typecheck/tests in `validate` is what gets deployed — not a fresh rebuild from rsynced source that could theoretically drift.
- Rollback becomes trivial: point Compose back at the previous image tag and restart — no rebuild needed.
- EC2 only needs `compose.yaml` and the `deploy/` folder — not the whole monorepo — so deploys are smaller.
- GitHub Container Registry (GHCR) is part of GitHub itself; no Docker Hub account needed.

**The `deploy` stage uses an IAM user + AWS Systems Manager (SSM), not SSH.** GitHub Actions authenticates to AWS with a dedicated IAM user's access keys, uploads the small deploy config to a private S3 bucket, then runs `deploy/deploy.sh pull-deploy` on the instance via `aws ssm send-command` — no SSH key, no open port 22 for CI, no SSH host-key management.

**Full setup walkthrough — IAM policy, S3 bucket, EC2 instance role, exact commands: see `IAM_DEPLOYMENT_SETUP.md`.** That's the file to follow end to end for setting up the credentials below. This section only summarizes the result.

### 9.1 GitHub Secrets and Variables

| Name | Kind | Required | Purpose |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID` | Secret | Yes | IAM user access key (see `IAM_DEPLOYMENT_SETUP.md` §3.4). |
| `AWS_SECRET_ACCESS_KEY` | Secret | Yes | IAM user secret key. |
| `AWS_REGION` | Variable | Yes | Your EC2 instance's AWS region, e.g. `us-east-1`. |
| `EC2_INSTANCE_ID` | Variable | Yes | Your instance ID, e.g. `i-0123456789abcdef0`. |
| `EC2_APP_DIR` | Variable | Yes | Absolute path to the app directory on EC2, e.g. `/home/ubuntu/Replit_porject`. |
| `DEPLOY_S3_BUCKET` | Variable | Yes | The private S3 bucket deploy config is staged through. |
| `EC2_HOST` | Variable | Yes | EC2 public IP or domain — used for the public smoke test, not for connecting. |
| `DEPLOY_BRANCH` | Variable | No (default `main`) | Which branch triggers an actual deploy; pushes to other branches still run `validate` via normal CI but the deploy pipeline no-ops. |

No GHCR-specific secret is needed — the pipeline pushes with the automatic `GITHUB_TOKEN`, and the packages are set to public visibility (see `IAM_DEPLOYMENT_SETUP.md` §3.5) so EC2 can pull with no registry credential at all.

If you have leftover `EC2_SSH_KEY` / `EC2_KNOWN_HOSTS` secrets or `EC2_USER` / `EC2_SSH_PORT` variables from an earlier SSH-based version of this pipeline, they're unused now and can be deleted.

### 9.4 First run

1. Complete the one-time AWS setup in `IAM_DEPLOYMENT_SETUP.md` (S3 bucket, EC2 instance role, IAM user, GHCR package visibility) and add the secrets/variables above.
2. Make sure `EC2_APP_DIR` already exists on EC2 with a working `compose.yaml` and `deploy/` folder (i.e. you've done the manual first deploy in sections 1–6 at least once) — the pipeline only ever syncs `compose.yaml` and `deploy/`, it does not bootstrap Docker, Nginx, or the host from scratch.
3. Push to `main`, or trigger manually: GitHub → repo → **Actions** → **Deploy portfolio to EC2** → **Run workflow**.
4. Watch the run. Each job (`gate` → `validate` → `build-and-push` → `deploy` → `smoke-test` → `report`) must go green in order. The final **Deployment summary** in the run's job summary shows the deployed commit, image tags, and the live URL.

### 9.5 Rollback

Automatic: if `deploy` or `smoke-test` fails, the `rollback` job runs by itself and reverts EC2 to the last successfully deployed image tags — using images already cached on the box, so it works even if GHCR is briefly unreachable. No data, volumes, or the Nginx config are touched.

Manual (from the EC2 instance, any time):
```bash
cd <EC2_APP_DIR>
./deploy/deploy.sh rollback     # reverts to the previous recorded release
./deploy/deploy.sh status       # confirm containers are healthy
```

Manual (force a specific older version without waiting for CI): re-run the **Deploy portfolio to EC2** workflow with **Run workflow** → `ref` set to the older commit SHA/branch/tag you want live.

There's no rollback target before the first successful pipeline-driven deploy — `./deploy/deploy.sh rollback` will say so clearly if `.deploy-state/previous.env` doesn't exist yet.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose build` fails or hangs | Out of memory on a small instance | Add swap (step 2.4) or upsize to `t3.small`+ |
| `docker: command not found` after `usermod -aG docker` | Group change needs a fresh login | Log out and `ssh` back in |
| Containers healthy on the box, site unreachable from browser | Security group doesn't allow port 80/443 | Add inbound rules (step 1.6) |
| Still unreachable after fixing security group | Host firewall (`ufw`) blocking it | `sudo ufw status`; if active, `sudo ufw allow 80,443/tcp` |
| Browser shows default "Welcome to nginx" page | Ubuntu's default site still enabled | `sudo rm -f /etc/nginx/sites-enabled/default && sudo systemctl reload nginx` |
| `nginx -t` fails | Syntax error or duplicate `server_name`/port binding | Read the exact line nginx reports and fix it before reloading |
| `curl 127.0.0.1:18080` works on EC2 but public IP doesn't | Confirms it's a network path issue (security group / ufw / wrong IP), not Docker | Re-check steps 1.6, 2.6, and confirm the public IP with `curl -s https://checkip.amazonaws.com` |
| `./deploy/deploy.sh deploy` fails at `health_check` | API or web container crash-looping | `docker compose logs api` / `docker compose logs web` to see the actual error |
| Disk fills up over time | Old Docker images/build cache accumulating | `docker system prune -f` (safe: only removes unused images/containers/cache) |

### Quick diagnostic sequence (run on the EC2 instance)
```bash
docker compose ps                          # are both containers "healthy"?
docker compose logs api --tail 50          # API crash reasons, if any
docker compose logs web --tail 50          # web/nginx crash reasons, if any
sudo systemctl status nginx                # is host nginx running?
sudo ss -tlnp | grep :80                   # is anything actually listening on 80?
sudo ufw status                            # host firewall blocking?
curl -I http://127.0.0.1/                  # does it work locally on the box?
curl -s https://checkip.amazonaws.com      # confirm current public IP matches what you're testing
```

---

## 11. Clean up / rollback

```bash
./deploy/deploy.sh down        # stop containers, keep images/config
docker compose down --rmi all  # stop containers and remove built images
```

To roll back to a previous version with `git`:
```bash
cd ~/developer-portfolio
git log --oneline -5           # find the commit to roll back to
git checkout <commit-sha>
./deploy/deploy.sh deploy
```
