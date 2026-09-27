cat > /tmp/uvcheck.sh <<'EOF'
#!/bin/bash
set -u
echo "=== uv identity ==="
uv --version
which uv
echo
echo "=== configs mounted ==="
ls -l /etc/uv/uv.toml /etc/pip.conf
echo
echo "=== CA trust to internal index ==="
curl -sS -o /dev/null -w "pypi.amf -> %{http_code}\n" https://pypi.amf/root/pypi/+simple/
echo
echo "=== uv resolves from pypi.amf ==="
uv venv /tmp/uvt >/dev/null && uv pip install --python /tmp/uvt/bin/python --no-cache requests 2>&1 | tail -6
/tmp/uvt/bin/python -c "import requests; print('uv install OK', requests.__version__)"
echo
echo "=== a slightly heavier resolve, to actually exercise HTTP/2-vs-1.1 differences ==="
uv pip install --python /tmp/uvt/bin/python --no-cache numpy pandas scikit-learn 2>&1 | tail -10
echo
echo "=== GPU / TF still fine ==="
python -c "import tensorflow as tf; print('TF GPUs:', tf.config.list_physical_devices('GPU'))"
echo
echo "=== the other tools ==="
pi --version; cursor-agent --version; claude --version; codex --version; herdr --version
EOF
chmod +x /tmp/uvcheck.sh && /tmp/uvcheck.sh
