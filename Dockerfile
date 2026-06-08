FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir aiohttp
COPY relay .
# TOKEN is set as an environment variable in Koyeb/Render dashboard
# PORT is set automatically by the platform
CMD ["python3", "relay", "--cloud"]
