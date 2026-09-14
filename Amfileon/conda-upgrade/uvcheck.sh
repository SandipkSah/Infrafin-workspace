#!/bin/bash
# Run this AS the container's own user (not root) inside conda-ssa, e.g.:
#   docker exec -u ssa -it conda-ssa bash -l
#   ./uvcheck.sh
#
# Verifies the things the ClickUp ticket actually cares about: uv is in the
# image, the per-user uv/pip config is mounted and trusted, and the GPU is
# visible to TensorFlow. Doesn't touch anything outside /tmp.

set -u

echo "=== configs mounted ==="
ls -l /etc/uv/uv.toml /etc/pip.conf
grep -o 'index-url = "https://[^@"]*@[^"/]*' /etc/uv/uv.toml | sed 's/:.*@/:***@/'

echo
echo "=== CA trust to internal index ==="
curl -sS -o /dev/null -w "pypi.amf -> %{http_code}\n" https://pypi.amf/root/pypi/+simple/
curl --cacert /etc/certs/CA.pem -sS -o /dev/null -w "pypi.amf (forced CA) -> %{http_code}\n" https://pypi.amf/root/pypi/+simple/

echo
echo "=== uv resolves from pypi.amf ==="
uv venv /tmp/uvt >/dev/null && uv pip install --python /tmp/uvt/bin/python --no-cache requests 2>&1 | tail -4
/tmp/uvt/bin/python -c "import requests; print('uv install OK', requests.__version__)"

echo
echo "=== pip via /etc/pip.conf ==="
python -m venv /tmp/pipt && /tmp/pipt/bin/pip install --no-cache-dir six 2>&1 | tail -3

echo
echo "=== GPU visible ==="
nvidia-smi -L
python -c "import tensorflow as tf; print('TF GPUs:', tf.config.list_physical_devices('GPU'))"

echo
echo "=== versions ==="
uv --version; conda --version; python --version
nvcc --version | tail -1
