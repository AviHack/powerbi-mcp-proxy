FROM python:3.11-slim

# Install deps as root, then drop privileges before copying app code.
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY pbi_mcp_remote.py .

# Run as non-root. App Service ignores this (it sets its own UID), but
# every other host (Fly, Railway, plain Docker) honors it.
RUN useradd --system --uid 10001 --no-create-home appuser \
 && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["gunicorn", "-k", "uvicorn.workers.UvicornWorker", "-b", "0.0.0.0:8000", "pbi_mcp_remote:app"]
