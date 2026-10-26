# Conduit Deployment

Automated build and deployment of the Conduit application (a Medium clone) with GitHub Actions. The application consists of an Angular frontend, a Django backend and a PostgreSQL database, running as Docker containers on a cloud VM.

This repository contains the source code of both applications, a multi-stage `Dockerfile` for each of them, a Docker Compose setup and a GitHub Actions workflow. On every push to `main`, the workflow builds the container images, pushes them to the **GitHub Container Registry (GHCR)** and deploys them to the VM via SSH. The VM only pulls and starts the finished images – nothing is built on the VM.

Docker Compose starts three services:

- **`frontend`** – the Angular 17 app, built with Node.js and served by **nginx**
- **`backend`** – the Django 1.10 REST API, running with the WSGI server **Gunicorn**
- **`database`** – **PostgreSQL 16.10** with a persistent volume

Only the frontend is published to the outside on port **8282**. nginx forwards all API requests (`/api/...`) to the backend inside the Docker network, so the backend and the database are not reachable from the internet. All credentials are loaded from a local `.env` file and are never stored in the repository.

The purpose of this project is to automate the release process of a containerized application: build and release are separated into two jobs, and every change on `main` is deployed to the VM without manual steps.

## Table of Contents

- [Quickstart](#quickstart)
  - [Prerequisites](#prerequisites)
  - [Automatic Deployment](#automatic-deployment)
  - [Run Locally](#run-locally)
- [Repository Contents](#repository-contents)
- [Usage](#usage)
  - [How It Works](#how-it-works)
  - [Deployment Workflow](#deployment-workflow)
  - [GitHub Secrets](#github-secrets)
  - [Changing the Deployment](#changing-the-deployment)
  - [Rollback to an Older Version](#rollback-to-an-older-version)
  - [Configuration with the .env File](#configuration-with-the-env-file)
  - [Non-Critical Configuration](#non-critical-configuration)
  - [Changing the Port](#changing-the-port)
  - [Backend Image](#backend-image)
  - [Frontend Image](#frontend-image)
  - [Images and Versions](#images-and-versions)
  - [Persistence](#persistence)
  - [Network](#network)
  - [Restart Behaviour](#restart-behaviour)
  - [Logs](#logs)
  - [Useful Commands](#useful-commands)
- [Changes to the Application Code](#changes-to-the-application-code)
- [Testing](#testing)
- [Known Issues](#known-issues)
- [Security Notes](#security-notes)

## Quickstart

### Prerequisites

**On the VM:**

- A Linux cloud VM with at least **2 GB of free RAM** and a public IP address
- **Docker Engine** and the **Docker Compose plugin v2** (`docker compose version`)
- The SSH user can run Docker without `sudo` (member of the `docker` group)
- Port **22/TCP** (SSH) and **8282/TCP** open in the firewall of the VM / cloud provider

**On GitHub:**

- A fork or copy of this repository with GitHub Actions enabled
- An SSH key pair for the deployment (the public key on the VM, the private key as GitHub Secret)
- The [GitHub Secrets](#github-secrets) listed below

> [!IMPORTANT]
> If port 8282 is not open in the firewall of the VM / cloud provider, the containers run but the application is not reachable.

### Automatic Deployment

```bash
# 1. Create an SSH key only for the deployment (without passphrase)
ssh-keygen -t ed25519 -f ~/.ssh/github_actions_conduit -C "github-actions-conduit" -N ""

# 2. Copy the public key to the VM
ssh-copy-id -i ~/.ssh/github_actions_conduit.pub <user>@<VM-IP>

# 3. Test the connection with this key only
ssh -o IdentitiesOnly=yes -i ~/.ssh/github_actions_conduit <user>@<VM-IP> "docker ps"
```

4. Add the [GitHub Secrets](#github-secrets) in **Settings → Secrets and variables → Actions**.
5. Push to `main` (or start the workflow manually in the **Actions** tab with **Run workflow**).
6. Open `http://<VM-IP>:8282` in the browser.

### Run Locally

```bash
git clone https://github.com/vadim-cebanu/conduit.git
cd conduit
cp .env.example .env        # set your own POSTGRES_PASSWORD and SECRET_KEY
docker compose up -d --build
docker compose ps
```

Open `http://localhost:8282` in the browser.

> [!NOTE]
> The first local build takes a few minutes, because the npm packages are installed and the Angular app is compiled.

## Repository Contents

| File&nbsp;/&nbsp;Folder&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; | Purpose |
|---|---|
| `backend/` | Source code of the Django backend (original project, see [Changes](#changes-to-the-application-code)). |
| `backend/Dockerfile` | Multi-stage build of the backend image (Python 3.6, Gunicorn). |
| `backend/entrypoint.sh` | Start script of the backend container: runs the database migrations and starts Gunicorn. |
| `backend/.dockerignore` | Keeps cache files, local databases and secrets out of the backend image. |
| `frontend/` | Source code of the Angular frontend (original project, see [Changes](#changes-to-the-application-code)). |
| `frontend/Dockerfile` | Multi-stage build of the frontend image (Node.js build, nginx runtime). |
| `frontend/nginx.conf` | nginx configuration: serves the Angular app and forwards `/api/` to the backend. |
| `frontend/.dockerignore` | Keeps `node_modules`, build output and secrets out of the frontend image. |
| `.github/workflows/deployment.yaml` | GitHub Actions workflow: builds and pushes the images to GHCR and deploys them to the VM via SCP and SSH. |
| `docker-compose.yaml` | Defines the services `frontend`, `backend` and `database` with ports, environment, volume, network and restart policy. |
| `.env.example` | Template for the configuration. Copy it to `.env` and set your own values. `.env` itself is not committed. |
| `.gitignore` | Keeps secrets (`.env`, keys) and log files out of the repository. |
| `README.md` | This documentation. |

`backend/` and `frontend/` also contain the original `README.md`, `.gitignore` and other files of the two projects.

## Usage

### How It Works

**Build and release:**

```
git push (main)
      │
      ▼
GitHub Actions
  ├── job build   ──► build backend + frontend images ──► push to ghcr.io
  │
  └── job deploy  (only if build was successful)
        ├── create .env from GitHub Secrets
        ├── SCP: copy docker-compose.yaml and .env to the VM
        └── SSH: docker compose pull / down / up -d
```

**Runtime on the VM:**

```
Browser ──► http://<VM-IP>:8282
                │
                ▼
          frontend (nginx)
            ├── /        ──► Angular app (static files)
            └── /api/... ──► backend:8000
                                │
                                ▼
                          backend (Gunicorn + Django)
                                │
                                ▼
                          database:5432 (PostgreSQL)
                          Volume db-data ──► /var/lib/postgresql/data

      all services run in the network conduit-net
```

1. The **database** starts first. A healthcheck (`pg_isready`) reports when PostgreSQL is ready.
2. The **backend** starts only when the database is healthy. `entrypoint.sh` runs `python manage.py migrate` and then starts Gunicorn.
3. The **frontend** serves the Angular app with nginx and forwards API requests to the backend.

### Deployment Workflow

The workflow `.github/workflows/deployment.yaml` runs on every push to `main` and can also be started manually (`workflow_dispatch`). It has two separate jobs:

**Job `build` – build and push the images**

| Step | Description |
|---|---|
| Checkout code | downloads the repository on the GitHub runner |
| Log in to GHCR | `docker/login-action` with the automatic `GITHUB_TOKEN` |
| Build and push | `docker/build-push-action` builds `./backend` and `./frontend` (matrix, in parallel) and pushes both images |

Each image gets two tags:

| Tag | Example | Purpose |
|---|---|---|
| `latest` | `ghcr.io/vadim-cebanu/conduit-backend:latest` | always the newest image |
| commit hash | `ghcr.io/vadim-cebanu/conduit-backend:1b7e929...` | exact, unchangeable version of one commit |

**Job `deploy` – release to the VM** (`needs: build`, so it only runs after a successful build)

| Step | Description |
|---|---|
| Create `.env` | writes the secrets and `APP_VERSION=<commit hash>` into a `.env` file on the runner |
| Copy files to VM | `appleboy/scp-action` copies `docker-compose.yaml` and `.env` to the folder `conduit` on the VM |
| Deploy | `appleboy/ssh-action` runs on the VM: `docker login ghcr.io`, `docker compose pull`, `docker compose down`, `docker compose up -d --no-build`, `docker compose ps`, `docker logout` |

The SSH script starts with `set -e`, so every failing command stops the script and the workflow ends with an error. If the build fails, the deploy job is not started at all.

> [!NOTE]
> `--no-build` makes sure that nothing is built on the VM. The VM only uses the images from GHCR. The `build:` section in `docker-compose.yaml` is only used for local builds.

### GitHub Secrets

All sensitive values are stored as GitHub Secrets (**Settings → Secrets and variables → Actions**) and are never part of the repository:

| Secret | Description |
|---|---|
| `SSH_HOST` | IP address of the VM |
| `SSH_USER` | user on the VM (must be able to run Docker) |
| `SSH_PRIVATE_KEY` | private key of the deployment SSH key (complete, including the `BEGIN` and `END` lines) |
| `POSTGRES_USER` | database user |
| `POSTGRES_PASSWORD` | database password |
| `SECRET_KEY` | secret key of Django |

`GITHUB_TOKEN` is created automatically by GitHub for every workflow run. It is used to push the images and to log in to GHCR on the VM, and it expires when the job is finished.

> [!WARNING]
> If a database already exists on the VM, `POSTGRES_USER` and `POSTGRES_PASSWORD` must match the values used when the volume was created. Otherwise the backend cannot connect to the database.

### Changing the Deployment

The workflow is configured with variables at the top of `deployment.yaml`:

```yaml
env:
  IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}
  DEPLOY_PATH: conduit
```

| Variable | Default | Description |
|---|---|---|
| `IMAGE_REGISTRY` | `ghcr.io/<repository owner>` | registry and namespace of the images |
| `DEPLOY_PATH` | `conduit` | folder on the VM (relative to the home directory of `SSH_USER`) |

**Example – deploy into another folder on the VM:**

```yaml
env:
  DEPLOY_PATH: apps/conduit
```

**Example – deploy from another branch:**

```yaml
on:
  push:
    branches:
      - main
      - release
```

**Example – add a non-secret setting for the VM:** add a line to the step *Create .env file from secrets*:

```yaml
          GUNICORN_WORKERS=5
```

> [!CAUTION]
> Docker Compose uses the folder name as project name. If `DEPLOY_PATH` is changed, a new volume is created and the existing data is not used.

### Rollback to an Older Version

Every image version stays in GHCR with its commit hash. To go back to an older version, set the hash in the `.env` file on the VM and restart:

```bash
cd ~/conduit
sed -i 's/^APP_VERSION=.*/APP_VERSION=<old commit hash>/' .env
docker compose pull
docker compose up -d --no-build
```

The next deployment from GitHub Actions overwrites `.env` again with the newest version.

### Configuration with the .env File

Not only the secrets, but also all values that may change (ports, workers, versions) are configured in the `.env` file. Locally it is created from `.env.example`; on the VM it is created by the deployment workflow. Docker Compose reads it automatically and inserts the values with the `${VARIABLE}` notation.

> [!NOTE]
> `.env` is your local configuration and is never committed. Only `.env.example` is part of the repository.

| Variable&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; | Default | Secret | Description |
|---|---|---|---|
| `FRONTEND_PORT` | `8282` | no | Port on the host where the application is reachable |
| `POSTGRES_DB` | `conduit` | no | Name of the database |
| `POSTGRES_USER` | – | yes | Database user (used by PostgreSQL and Django) |
| `POSTGRES_PASSWORD` | – | yes | Password of the database user |
| `SECRET_KEY` | – | yes | Secret key of Django |
| `DEBUG` | `False` | no | Django debug mode. Keep `False` outside of development |
| `ALLOWED_HOSTS` | `backend,localhost` | no | Hosts accepted by Django (comma separated) |
| `GUNICORN_WORKERS` | `3` | no | Number of Gunicorn worker processes |
| `IMAGE_REGISTRY` | `ghcr.io/vadim-cebanu` | no | Registry and namespace of the own images |
| `APP_VERSION` | `latest` | no | Tag of the own images (`latest` or a commit hash) |
| `POSTGRES_VERSION` | `16.10` | no | Version of the PostgreSQL image |
| `PYTHON_VERSION` | `3.6` | no | Python base image of the backend (build argument) |
| `NODE_VERSION` | `20.18` | no | Node.js base image for the frontend build (build argument) |
| `NGINX_VERSION` | `1.27` | no | nginx base image of the frontend (build argument) |

Generate strong values for the secrets:

```bash
openssl rand -base64 24                                   # POSTGRES_PASSWORD
python3 -c "import secrets; print(secrets.token_urlsafe(50))"   # SECRET_KEY
```

PostgreSQL and Django use the **same** variables (`POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`), so the database credentials always match.

> [!WARNING]
> The PostgreSQL password is only set when the database volume is created for the first time. Changing `POSTGRES_PASSWORD` later has no effect on an existing volume. See [Persistence](#persistence).

### Non-Critical Configuration

Values that are not secret are written directly in `docker-compose.yaml`, for example the database host of the backend:

```yaml
environment:
  POSTGRES_HOST: database
  POSTGRES_PORT: "5432"
```

`database` is the name of the database service. Docker resolves it to the IP address of the container inside the network.

Django reads all its settings from these environment variables in `backend/conduit/settings.py`:

```python
SECRET_KEY = os.environ.get('SECRET_KEY')
DEBUG = os.environ.get('DEBUG', 'False') == 'True'
ALLOWED_HOSTS = os.environ.get('ALLOWED_HOSTS', 'localhost').split(',')
```

**Example – turn on the Django debug mode for local testing:**

```dotenv
DEBUG=True
```

```bash
docker compose up -d
```

### Changing the Port

The application is reachable on `FRONTEND_PORT` (default `8282`). Inside the container nginx always listens on port `80`. To use another port, change it in `.env`:

```dotenv
FRONTEND_PORT=8080
```

Then run `docker compose up -d` and open the new port in the firewall.

> [!NOTE]
> Only `FRONTEND_PORT` changes. The backend (`8000`) and the database (`5432`) are not published to the host.

### Backend Image

The backend `Dockerfile` uses a **multi-stage build**:

| Stage | Base image | What happens |
|---|---|---|
| `builder` | `python:3.6-slim` | installs the packages from `requirements.txt` into `/install` |
| final | `python:3.6-slim` | copies only the installed packages and the source code |

The Python version is a build argument with a default value:

```dockerfile
ARG PYTHON_VERSION=3.6
FROM python:${PYTHON_VERSION}-slim AS builder
```

Environment variables set in the `Dockerfile`:

| Variable | Default | Description |
|---|---|---|
| `PYTHONDONTWRITEBYTECODE` | `1` | no `.pyc` files |
| `PYTHONUNBUFFERED` | `1` | logs appear immediately in `docker logs` |
| `BACKEND_PORT` | `8000` | port Gunicorn listens on |
| `GUNICORN_WORKERS` | `3` | number of Gunicorn worker processes |

The `ENTRYPOINT` starts `entrypoint.sh`, which runs the migrations and then the **WSGI server Gunicorn** (not the Django development server):

```sh
exec gunicorn conduit.wsgi:application --bind "0.0.0.0:${BACKEND_PORT}" ...
```

> [!NOTE]
> Python 3.6 is used on purpose: Django 1.10 does not run on newer Python versions.

**Example – use more Gunicorn workers:** change the value in `.env`:

```dotenv
GUNICORN_WORKERS=5
```

```bash
docker compose up -d
```

### Frontend Image

The frontend `Dockerfile` also uses a **multi-stage build**:

| Stage | Base image | What happens |
|---|---|---|
| `build` | `node:20.18-alpine` | `npm ci` and `npm run build` (production build) |
| final | `nginx:1.27-alpine` | copies only the built files from `dist/angular-conduit` |

The Node.js and nginx versions are build arguments with default values:

```dockerfile
ARG NODE_VERSION=20.18
ARG NGINX_VERSION=1.27
FROM node:${NODE_VERSION}-alpine AS build
...
FROM nginx:${NGINX_VERSION}-alpine
```

The final image contains no Node.js and no `node_modules`, so it stays small.

`HUSKY=0` is set in the build stage, because the Git hooks of the project (`husky`) cannot be installed without a `.git` folder.

`nginx.conf` does two things:

```nginx
location /api/ {
    proxy_pass http://backend:8000;      # API requests go to the backend
}
location / {
    try_files $uri $uri/ /index.html;    # all other routes are handled by Angular
}
```

> [!IMPORTANT]
> The Angular code is compiled during the build. After changes in `frontend/`, rebuild the image with `docker compose up -d --build frontend`.

### Images and Versions

All image versions are pinned, so every build uses the same software:

| Service | Image | Variable in `.env` |
|---|---|---|
| `database` | `postgres:16.10` | `POSTGRES_VERSION` |
| `backend` | `ghcr.io/vadim-cebanu/conduit-backend:<tag>` | `IMAGE_REGISTRY`, `APP_VERSION`, `PYTHON_VERSION` |
| `frontend` | `ghcr.io/vadim-cebanu/conduit-frontend:<tag>` | `IMAGE_REGISTRY`, `APP_VERSION`, `NODE_VERSION`, `NGINX_VERSION` |

In `docker-compose.yaml` each own image has a build context, build arguments and a name with a version tag:

```yaml
backend:
  build:
    context: ./backend
    args:
      PYTHON_VERSION: ${PYTHON_VERSION:-3.6}
  image: ${IMAGE_REGISTRY:-ghcr.io/vadim-cebanu}/conduit-backend:${APP_VERSION:-latest}
```

The image name points to GHCR, so the VM can pull the images built by the workflow. Locally, `docker compose up -d --build` still builds the images from the `build:` section.

**Example – update nginx:** change the default value in `frontend/Dockerfile` (or the build argument in the workflow), then push to `main`:

```dockerfile
ARG NGINX_VERSION=1.28
```

The workflow builds new images with the new commit hash and deploys them.

> [!WARNING]
> Make a backup of the database before changing `POSTGRES_VERSION`. A database created with a newer major version cannot be opened with an older one.

### Persistence

The named volume `db-data` is mounted to `/var/lib/postgresql/data` in the database container. All application data (users, articles, comments) survives container restarts, `docker compose down` and image rebuilds.

Docker Compose puts the project folder name in front of the volume name. Show it with:

```bash
docker volume ls
```

Create a database backup:

```bash
docker compose exec database sh -c 'pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}"' > backup.sql
```

> [!CAUTION]
> `docker compose down -v` deletes the volume and therefore all data.

### Network

All three services are connected to the network `conduit-net`. In this network the containers find each other by service name (`frontend`, `backend`, `database`). Only the frontend port is published to the host.

### Restart Behaviour

All services use `restart: unless-stopped`. Docker restarts a container automatically when it stops because of an error or after a reboot of the machine. It is only not restarted when it was stopped manually (`docker compose stop`).

### Logs

Gunicorn and nginx write their logs to the standard output, so they can be read with Docker:

```bash
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs -f database
```

Save the logs of a container to a file:

```bash
docker logs conduit-backend-1 > backend-logs.txt
docker logs conduit-frontend-1 > frontend-logs.txt
docker logs conduit-database-1 > database-logs.txt
```

The container names are shown by `docker compose ps`. Log files (`*-logs.txt`) are ignored by Git.

### Useful Commands

| Command&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; | Description |
|---|---|
| `docker compose up -d --build` | Build the images and start all services |
| `docker compose up -d` | Apply changes from `.env` or `docker-compose.yaml` |
| `docker compose up -d --build frontend` | Rebuild and restart only the frontend |
| `docker compose ps` | Show status and ports |
| `docker images \| grep conduit` | Show the own images and their version tags |
| `docker compose logs -f backend` | Follow the backend logs |
| `docker compose restart backend` | Restart the backend |
| `docker compose down` | Stop and remove the containers (the data stays in the volume) |
| `docker compose exec database psql -U <user> -d conduit` | Open the PostgreSQL console |

## Changes to the Application Code

The frontend (Angular 17) and the backend (Django 1.10) are original projects. Only these changes were made, so the application works in containers:

| File | Change | Reason |
|---|---|---|
| `backend/requirements.txt` | added `gunicorn==20.1.0` and `psycopg2-binary==2.8.6` | WSGI server and PostgreSQL driver (versions compatible with Python 3.6 and Django 1.10) |
| `backend/conduit/settings.py` | PostgreSQL instead of SQLite, `SECRET_KEY`, `DEBUG` and `ALLOWED_HOSTS` from environment variables | no secrets in the code, configuration from outside |
| `backend/conduit/apps/articles/urls.py` | feed route moved before the router, optional trailing slash for creating articles | `/api/articles/feed` and `POST /api/articles/` returned 404 |
| `frontend/src/app/core/interceptors/api.interceptor.ts` | API URL changed from `https://api.realworld.io/api` to `/api` | the frontend uses the own backend through the nginx proxy |
| `frontend/src/styles.css`, `frontend/src/index.html` | theme CSS added locally, external link removed | the original CSS host (`demo.productionready.io`) is offline |

## Testing

**0. The workflow runs without errors:**

Push to `main` or start the workflow with **Actions → Build and Deploy → Run workflow**. All jobs (`build (backend)`, `build (frontend)`, `Deploy to VM`) must finish with a green check mark. The images appear under **Packages** in the GitHub profile.

On the VM, the containers must use the images from GHCR with the commit hash:

```bash
cd ~/conduit
docker compose ps
```

```
conduit-backend-1    ghcr.io/vadim-cebanu/conduit-backend:<commit hash>    ...   Up
conduit-frontend-1   ghcr.io/vadim-cebanu/conduit-frontend:<commit hash>   ...   Up
```

The following tests are run on the VM in the folder `~/conduit`.

**1. All services are running:**

```bash
docker compose ps
```

All three services must have the status `Up`, the database `(healthy)`, and the frontend must show `0.0.0.0:8282->80/tcp`.

**2. The application is reachable:**

Open `http://<VM-IP>:8282`. Sign up, create an article, write a comment and open your profile. The data is loaded on every page.

**3. The API works through the proxy:**

```bash
curl http://localhost:8282/api/articles
```

The output is JSON, for example `{"articles": [], "articlesCount": 0}`.

**4. The backend runs with a WSGI server:**

```bash
docker compose logs backend | grep -i gunicorn
```

The output contains `Starting gunicorn` and `Listening at: http://0.0.0.0:8000`.

**5. The data is kept after a restart and after a new deployment:**

```bash
docker compose down
docker compose up -d --no-build
```

Log in again: the user and the articles still exist. The same is true after a new run of the workflow.

**6. The containers restart automatically after an error:**

```bash
docker inspect -f '{{.RestartCount}}' conduit-backend-1
docker compose exec backend kill 1
sleep 15
docker compose ps
docker inspect -f '{{.RestartCount}}' conduit-backend-1
```

The Gunicorn process is stopped without `docker stop`. Docker starts the container again and the restart counter increases by one. The same test works for `frontend` and `database`.

**7. The logs can be saved:**

```bash
docker logs conduit-backend-1 > backend-logs.txt
cat backend-logs.txt
```

## Known Issues

The frontend (Angular 17, 2024) and the backend (Django 1.10, 2017) were developed independently. The focus of this project is the containerization, so the application itself was only changed where it was necessary to run it (see [Changes to the Application Code](#changes-to-the-application-code)).

Known remaining issues:

- Deleting an article returns `405 Method Not Allowed`, because the original backend does not implement this action.
- The Django admin (`/admin`) is not available through the frontend and has no static files, because only `/api/` is forwarded by nginx.
- Python 3.6, Django 1.10 and the other backend packages are outdated and no longer receive security updates. They are used on purpose, because the application is not compatible with newer versions.

## Security Notes

- No passwords, tokens, usernames, IP addresses or SSH keys are stored in this repository.
- The VM address, the SSH user, the SSH key and all credentials are stored as GitHub Secrets.
- A separate SSH key is used only for the deployment, so it can be removed without affecting other access.
- The temporary `GITHUB_TOKEN` is used to access GHCR, and `docker logout` is run on the VM after the deployment.
- All credentials are loaded from `.env`, which is excluded by `.gitignore` and both `.dockerignore` files. On the VM it is created by the workflow.
- The credentials have no default values, so the setup never runs with a known password.
- Only the frontend port is published. The backend and the database are only reachable inside the Docker network.
- `DEBUG` is `False` by default.

> [!TIP]
> The original `SECRET_KEY` of the project is visible in the Git history. Always set a new, random value in `.env`.