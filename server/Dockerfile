FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt requirements-roboflow.txt ./
# The Roboflow endpoints need requirements-roboflow.txt, which holds Pillow on
# 12.x (see that file). Build with --build-arg WITH_ROBOFLOW=false for an image
# without those endpoints that installs Pillow 13.
ARG WITH_ROBOFLOW=true
# ultralytics depends on the full opencv-python package, which needs
# graphics libraries that python:3.11-slim doesn't include. Both packages
# install into the same cv2 folder, so remove them and keep only the
# headless build.
RUN if [ "$WITH_ROBOFLOW" = "true" ]; then extra="-r requirements-roboflow.txt"; else extra=""; fi \
    && pip install --no-cache-dir -r requirements.txt $extra \
    && pip uninstall -y opencv-python opencv-python-headless \
    && pip install --no-cache-dir "opencv-python-headless>=4.10,<5.0"

COPY . .

EXPOSE 8000

# One worker, not two. Disc-flight jobs live in a process-local registry
# (DiscFlightJobManager.jobs), so with two workers a job created in one
# would 404 when the client's next poll landed on the other. docker-compose.yml
# already pins this; the default matters for anyone running the image directly,
# where the compose override does not apply. Scale out only once that registry
# and its cancellation signal move into the shared durable services.
CMD gunicorn main:app -w 1 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:${PORT:-8000}
