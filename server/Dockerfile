FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

# One worker, not two. Disc-flight jobs live in a process-local registry
# (DiscFlightJobManager.jobs), so with two workers a job created in one
# would 404 when the client's next poll landed on the other. docker-compose.yml
# already pins this; the default matters for anyone running the image directly,
# where the compose override does not apply. Scale out only once that registry
# and its cancellation signal move into the shared durable services.
CMD gunicorn main:app -w 1 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:${PORT:-8000}
