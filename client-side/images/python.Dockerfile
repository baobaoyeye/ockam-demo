# Python client image — base + Python 3.12 + ockam-client SDK + pymysql.
ARG BASE=ockam-demo-client-base:latest
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install ockam-client + pymysql in a venv to keep system clean.
COPY sdk-python /opt/sdk-python
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install /opt/sdk-python pymysql

ENV PATH=/opt/venv/bin:$PATH

WORKDIR /app
COPY examples/python_mysql.py /app/python_mysql.py

CMD ["python", "/app/python_mysql.py"]
