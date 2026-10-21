# Python version (build argument with default value)
ARG PYTHON_VERSION=3.6

# ---------- Stage 1: install the Python dependencies ----------
FROM python:${PYTHON_VERSION}-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Stage 2: small runtime image ----------
FROM python:${PYTHON_VERSION}-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BACKEND_PORT=8000 \
    GUNICORN_WORKERS=3

WORKDIR /app

COPY --from=builder /install /usr/local
COPY . . 

EXPOSE ${BACKEND_PORT}

ENTRYPOINT ["sh", "/app/entrypoint.sh"]