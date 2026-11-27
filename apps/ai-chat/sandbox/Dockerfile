# Python code-execution sandbox. Slim base, no third-party deps (stdlib only),
# runs as a non-root user. The strong isolation is applied at RUN time by the
# container flags / compose (read-only rootfs, dropped caps, no egress network).
FROM python:3.13-slim

# Unprivileged user to run both the service and the executed code.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin sandbox

WORKDIR /app
COPY app.py .

USER sandbox
EXPOSE 8000

# -u: unbuffered, so logs flush immediately.
CMD ["python", "-u", "app.py"]
