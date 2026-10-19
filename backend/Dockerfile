FROM python:3.6-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.6-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BACKEND_PORT=8000 \
    GUNICORN_WORKERS=3

WORKDIR /app

COPY --from=builder /install /usr/local
COPY . . 

EXPOSE ${BACKEND_PORT}

ENTRYPOINT ["sh", "/app/entrypoint.sh"]