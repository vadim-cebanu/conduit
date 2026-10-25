#!/bin/sh
set -e

#create or update the database tables
python manage.py migrate --noinput

# start the WSGI server (not the Django dev server)

exec gunicorn conduit.wsgi:application \
    --bind "0.0.0.0:${BACKEND_PORT}" \
    --workers "${GUNICORN_WORKERS}" \
    --access-logfile - \
    --error-logfile -