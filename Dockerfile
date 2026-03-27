# =============================================================================
# Stage 1: Builder
# Install dependencies into an isolated virtual environment.
# Build tools and pip cache never reach the final image.
# =============================================================================
FROM python:3.9-slim AS builder

WORKDIR /app

COPY requirements.txt .

RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# =============================================================================
# Stage 2: Production
# Lean image — only the venv and application code are copied across.
# Runs as a non-root user; curl is present only for the health check probe.
# =============================================================================
FROM python:3.9-slim AS production

WORKDIR /app

# Install curl (needed by the HEALTHCHECK command) and clean up in one layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create the non-root user BEFORE copying files so --chown resolves correctly
RUN useradd -m -u 1001 appuser

# Copy the pre-built virtual environment from the builder stage
COPY --from=builder /opt/venv /opt/venv

# Copy application source with correct ownership in a single layer
COPY --chown=appuser:appuser . .

# Make the virtual environment's binaries available on PATH
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Drop privileges — container never runs as root
USER appuser

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# Use Gunicorn (production WSGI server) instead of the Flask dev server
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
     "--timeout", "30", "--access-logfile", "-", "app:app"]
