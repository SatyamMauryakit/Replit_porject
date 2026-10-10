# Developer Portfolio

React/Vite developer portfolio with a small Express health API.

## Run & Operate

- The `artifacts/dev-portfolio: web` workflow serves the portfolio preview.
- The `artifacts/api-server: API Server` workflow serves `/api/healthz`.
- Install dependencies on a fresh import with `pnpm install --frozen-lockfile`.
- `pnpm run typecheck` checks the workspace.
- `pnpm run build` typechecks and builds workspace packages. The frontend build requires `PORT=19980 BASE_PATH=/`.
- Run production containers with `docker compose up --build --detach --wait`; open `http://localhost:18080`.
- `docker compose logs --follow` views container logs; `docker compose down` stops and removes them.
- The Replit workflows supply `PORT` and `BASE_PATH`. No database or external credentials are required for the current portfolio/API health endpoint.

## Stack

- Node.js 24, pnpm 10.26.1, TypeScript 5.9
- Frontend: React, Vite, Tailwind CSS
- API: Express 5
- Production containers: Nginx frontend and Node API, built from multi-stage Dockerfiles under `deploy/`

## GitHub

- GitHub remote: `SatyamMauryakit/Replit_porject`; current working branch: `aws/deployment-setup`; target branch: `main`.
- `.github/workflows/ci.yml` validates and builds changes on `main` pushes, pull requests to `main`, and manual dispatch. It does not publish or deploy.
- Replit's Git pane supports Auto-sync; editor saves themselves are not Git commits. If Auto-sync is not enabled, stage, commit, and push in the Git pane.
- `.github/workflows/deploy.yml` is a separate pre-existing workflow that can publish Docker Hub images and deploy to AWS when configured. It is outside the CI-only workflow.
