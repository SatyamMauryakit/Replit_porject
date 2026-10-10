# Developer Portfolio deployment (simple EC2 + Docker Compose)

Repository: `SatyamMauryakit/Replit_porject`

This project is a pnpm workspace generated for Replit and contains:
- a frontend (`artifacts/dev-portfolio`) built with Vite/React
- an API (`artifacts/api-server`) built with Express
- Docker deployment files that run both services behind Nginx

The deployment model in this repo is now intentionally simple:
- **No dedicated deploy Linux user is required**
- **No Docker Hub publishing is required**
- **No blue/green slot switching is used**
- EC2 runs the app directly with `docker compose up --build`

---

## Repository files used for deployment

| File | Purpose |
| --- | --- |
| `compose.yaml` | Defines `api` and `web` services; only web is bound to `127.0.0.1:18080`; API stays internal. |
| `deploy/Dockerfile.api` | Production build/runtime image for Express API. |
| `deploy/Dockerfile.frontend` | Production build/runtime image for frontend Nginx container. |
| `deploy/nginx/container.conf` | In-container Nginx config: SPA fallback + `/api/*` proxy to `api:5000`. |
| `deploy/nginx/developer-portfolio.conf` | Host Nginx virtual host for public `80/443`, proxies to localhost compose web port. |
| `deploy/nginx/developer-portfolio-upstream.conf` | Host Nginx snippet pointing to `http://127.0.0.1:18080`. |
| `deploy/deploy.sh` | Simple helper for compose deploy/start/stop/log/health commands using current EC2 user. |
| `.github/workflows/ci.yml` | CI checks/build for PRs/pushes to `main` (no deployment). |
| `.github/workflows/deploy.yml` | Optional manual workflow to copy repo to EC2 and run compose deploy over SSH. |

---

## Runtime architecture

1. Host Nginx listens on public ports **80/443**.
2. Host Nginx forwards traffic to `127.0.0.1:18080`.
3. Docker Compose `web` container serves the SPA and proxies `/api/*` to `api:5000` on Docker network.
4. API container is **not publicly exposed**.

This keeps only host Nginx public and preserves SPA routes + API proxy behavior.

---

## EC2 setup (Ubuntu, existing default user)

> Use your normal EC2 login user (typically `ubuntu`). Do not create a separate deploy user.

### 1) Security group

Allow inbound:
- TCP `80` from internet
- TCP `443` from internet
- TCP `22` only from your trusted admin/deployment source

Do **not** open `5000` or `18080` publicly.

### 2) Install Docker and Nginx

```bash
sudo apt-get update
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

Optional (to run Docker without `sudo`):
```bash
sudo usermod -aG docker "$USER"
# re-login for group change to apply
```

### 3) Copy or clone this repository on EC2

Example path:
```bash
mkdir -p ~/developer-portfolio
cd ~/developer-portfolio
# either git clone, or copy files from your machine/CI
```

### 4) Install host Nginx site config

Edit `deploy/nginx/developer-portfolio.conf` and replace:
- `server_name your-domain.example;`

Then install config:

```bash
sudo install -d -o root -g root -m 0755 /etc/nginx/snippets
sudo install -o root -g root -m 0644 \
  deploy/nginx/developer-portfolio-upstream.conf \
  /etc/nginx/snippets/developer-portfolio-upstream.conf
sudo install -o root -g root -m 0644 \
  deploy/nginx/developer-portfolio.conf \
  /etc/nginx/sites-available/developer-portfolio
sudo ln -s /etc/nginx/sites-available/developer-portfolio /etc/nginx/sites-enabled/developer-portfolio

sudo nginx -t
sudo systemctl reload nginx
```

If the symlink already exists, keep it and only update/test/reload.

### 5) Deploy with Docker Compose

From repo root:

```bash
chmod +x deploy/deploy.sh
./deploy/deploy.sh deploy
```

The script will:
- run `docker compose up --build -d --wait`
- keep API internal
- verify health via `http://127.0.0.1:18080/` and `/api/healthz`

---

## Day-2 operations on EC2

From repository root:

```bash
./deploy/deploy.sh status          # container status
./deploy/deploy.sh logs            # recent logs
./deploy/deploy.sh logs web        # logs for one service
./deploy/deploy.sh health          # local health checks
./deploy/deploy.sh restart         # restart without rebuild
./deploy/deploy.sh down            # stop containers
./deploy/deploy.sh deploy          # rebuild + restart
```

Equivalent raw compose commands:

```bash
docker compose up --build -d --wait
docker compose ps
docker compose logs --tail=100
docker compose down
```

---

## Optional domain + HTTPS

After DNS points to EC2 and port 80 is reachable:

```bash
sudo certbot --nginx -d your-real-domain.example --redirect
sudo certbot renew --dry-run
```

---

## GitHub Actions workflows

### CI (`.github/workflows/ci.yml`)
- Runs on `push`/`pull_request` to `main`
- Installs workspace deps with locked pnpm lockfile
- Runs lint/test if present, typecheck, workspace build, compose validation, docker compose build
- **Does not deploy**

### Deploy (`.github/workflows/deploy.yml`)
- Manual only (`workflow_dispatch`) to avoid duplicate pipelines
- Copies repository files to EC2 over SSH
- Runs `deploy/deploy.sh deploy` on EC2 using your existing EC2 login user

If you use this optional workflow, set:
- repository variable `EC2_HOST`
- optional repository variable `EC2_USER` (defaults to `ubuntu`)
- optional repository variable `EC2_APP_DIR` (defaults to `/home/<EC2_USER>/developer-portfolio`)
- repository secret `EC2_SSH_PRIVATE_KEY`

No Docker Hub credentials are required for this deployment path.

---

## Replit → GitHub → EC2 flow

- Replit editor changes are local until committed/pushed.
- CI runs when commits reach GitHub `main` or PRs target `main`.
- To deploy, either:
  1. SSH to EC2 and run `./deploy/deploy.sh deploy`, or
  2. Trigger the manual `Deploy portfolio to EC2` workflow in GitHub Actions.

---

## Local validation commands

```bash
pnpm install --frozen-lockfile
pnpm -r --if-present run lint
pnpm -r --if-present run test
pnpm run typecheck
pnpm run build
docker compose config --quiet
docker compose build
```

Do not commit secrets (`.env`, private keys, cloud credentials).
