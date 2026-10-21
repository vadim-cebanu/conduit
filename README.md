# Conduit in Docker

A Docker Compose setup for running the Conduit application (a Medium clone) with an Angular frontend, a Django backend and a PostgreSQL database.

This repository contains the source code of both applications together with everything needed to run them as containers. Each application has its own multi-stage `Dockerfile`, and Docker Compose starts three services:

- **`frontend`** – the Angular 17 app, built with Node.js and served by **nginx**
- **`backend`** – the Django 1.10 REST API, running with the WSGI server **Gunicorn**
- **`database`** – **PostgreSQL 16** with a persistent volume

Only the frontend is published to the outside on port **8282**. nginx forwards all API requests (`/api/...`) to the backend inside the Docker network, so the backend and the database are not reachable from the internet. All credentials are loaded from a local `.env` file and are never stored in the repository.

The purpose of this project is to containerize an existing, partly outdated application and run it on any machine with Docker in a reproducible way.

## Table of Contents

- [Quickstart](#quickstart)
  - [Prerequisites](#prerequisites)
  - [Start the Application](#start-the-application)
- [Repository Contents](#repository-contents)
- [Usage](#usage)
  - [How It Works](#how-it-works)
  - [Configuration with the .env File](#configuration-with-the-env-file)
  - [Non-Critical Configuration](#non-critical-configuration)
  - [Changing the Port](#changing-the-port)
  - [Backend Image](#backend-image)
  - [Frontend Image](#frontend-image)
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

- A Linux machine or cloud VM with at least **2 GB of free RAM**
- **Docker Engine** and the **Docker Compose plugin v2** (`docker compose version`)
- Port **8282/TCP** open in the firewall of the VM / cloud provider
- Internet access during the build (to download the base images and packages)

> [!IMPORTANT]
> If port 8282 is not open in the firewall of the VM / cloud provider, the containers run but the application is not reachable.

### Start the Application

```bash
# 1. Clone the repository
git clone <repository-url>
cd conduit

# 2. Create your configuration from the template
cp .env.example .env

# 3. Set your own values for POSTGRES_PASSWORD and SECRET_KEY
nano .env

# 4. Build the images and start all services in the background
docker compose up -d --build

# 5. Check that all three containers are running
docker compose ps
```

Open `http://<VM-IP>:8282` in the browser (on your own computer: `http://localhost:8282`).

> [!NOTE]
> The first build takes a few minutes, because the npm packages are installed and the Angular app is compiled.

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
| `docker-compose.yaml` | Defines the services `frontend`, `backend` and `database` with ports, environment, volume, network and restart policy. |
| `.env.example` | Template for the configuration. Copy it to `.env` and set your own values. `.env` itself is not committed. |
| `.gitignore` | Keeps secrets (`.env`, keys) and log files out of the repository. |
| `README.md` | This documentation. |

`backend/` and `frontend/` also contain the original `README.md`, `.gitignore` and other files of the two projects.

## Usage

### How It Works

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

### Configuration with the .env File

All secrets and changeable values are configured in the `.env` file (created from `.env.example`). Docker Compose reads it automatically and inserts the values with the `${VARIABLE}` notation.

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

**Example – use more Gunicorn workers:** add the variable to the `backend` service in `docker-compose.yaml`:

```yaml
environment:
  GUNICORN_WORKERS: "5"
```

### Frontend Image

The frontend `Dockerfile` also uses a **multi-stage build**:

| Stage | Base image | What happens |
|---|---|---|
| `build` | `node:20.18-alpine` | `npm ci` and `npm run build` (production build) |
| final | `nginx:1.27-alpine` | copies only the built files from `dist/angular-conduit` |

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

**5. The data is kept after a restart:**

```bash
docker compose down
docker compose up -d
```

Log in again: the user and the articles still exist.

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
- All credentials are loaded from `.env`, which is excluded by `.gitignore` and both `.dockerignore` files.
- The credentials have no default values, so the setup never runs with a known password.
- Only the frontend port is published. The backend and the database are only reachable inside the Docker network.
- `DEBUG` is `False` by default.

> [!TIP]
> The original `SECRET_KEY` of the project is visible in the Git history. Always set a new, random value in `.env`.
