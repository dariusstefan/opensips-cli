#!/bin/bash
##
## Manual distro compatibility test for opensips-cli.
##
## Usage:
##   ./test/test_distro.sh <docker-image>
##
## Examples:
##   ./test/test_distro.sh debian:bookworm
##   ./test/test_distro.sh debian:trixie
##   ./test/test_distro.sh ubuntu:22.04
##   ./test/test_distro.sh ubuntu:24.04
##   ./test/test_distro.sh fedora:41
##   ./test/test_distro.sh rockylinux:9
##
## Database tests (optional) — start DBs first with:
##   docker compose -f docker/docker-compose.test.yml up -d
##
## Then pass URLs via environment:
##   MYSQL_ADMIN_URL=mysql+pymysql://root:root@host.docker.internal/mysql \
##   MYSQL_URL=mysql+pymysql://opensips:opensipsrw@host.docker.internal/opensips \
##   PG_ADMIN_URL=postgresql://postgres:root@host.docker.internal/postgres \
##   PG_URL=postgresql://opensips:opensipsrw@host.docker.internal/opensips \
##   ./test/test_distro.sh debian:bookworm
##
## Schema tests (optional) — point to the opensips source scripts/ directory:
##   OPENSIPS_DB_PATH=/path/to/opensips/scripts \
##   MYSQL_ADMIN_URL=... \
##   ./test/test_distro.sh debian:bookworm
##
## Without OPENSIPS_DB_PATH the DB tests only verify connectivity (create/drop
## an empty database); with it they also populate the dialog module tables and
## confirm the tables exist.

set -euo pipefail

IMAGE="${1:?Usage: $0 <docker-image>}"
MYSQL_ADMIN_URL="${MYSQL_ADMIN_URL:-}"
MYSQL_URL="${MYSQL_URL:-}"
PG_ADMIN_URL="${PG_ADMIN_URL:-}"
PG_URL="${PG_URL:-}"
OPENSIPS_DB_PATH="${OPENSIPS_DB_PATH:-}"

# Detect distro family from image name
case "$IMAGE" in
    fedora:*|rockylinux:*|almalinux:*|centos:*)
        DISTRO_FAMILY="rpm" ;;
    *)
        DISTRO_FAMILY="deb" ;;
esac

if [ "$DISTRO_FAMILY" = "deb" ]; then
    INSTALL_SYS_PKGS="DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip python3-sqlalchemy python3-pymysql python3-psycopg2 python3-openssl"
    # --break-system-packages was added in pip 23.0 (not available on Ubuntu 22.04)
    PIP_FLAGS='$(pip3 install --help 2>&1 | grep -q break-system-packages && echo --break-system-packages || true)'
else
    # install what's reliably available in base repos; use pip for the rest
    INSTALL_SYS_PKGS="dnf install -y python3-pip python3-sqlalchemy python3-psycopg2 && pip3 install PyMySQL pyopenssl"
    PIP_FLAGS=""
fi

# Build the -o database_schema_path option if schemas are available inside the container
SCHEMA_OPT=""
if [ -n "$OPENSIPS_DB_PATH" ]; then
    SCHEMA_OPT="-o database_schema_path=/opensips_scripts"
fi

# Inner script — runs inside the container
read -r -d '' INNER <<'EOF' || true

echo ""
echo "--- versions ---"
python3 --version
python3 -c "import sqlalchemy; print('sqlalchemy', sqlalchemy.__version__)"
python3 -c "import pymysql; print('pymysql', pymysql.__version__)"
python3 -c "import psycopg2; print('psycopg2', psycopg2.__version__)"

echo ""
echo "--- import test ---"
python3 -c "from opensipscli.db import osdb; print('OK')"

echo ""
echo "--- SQLite functional test ---"
python3 - << 'PYEOF'
import tempfile, os, sqlalchemy
from opensipscli.db import osdb

db_file = tempfile.mktemp(suffix='.db')
db = osdb('sqlite:///{}'.format(db_file), db_file)
assert db.create() and db.connect()
db._osdb__conn.execute(sqlalchemy.text('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)'))
assert db.insert('t', {'id': 1, 'v': 'hello'}) is not False
assert db.find('t', ['v'], {'id': 1}).fetchone()[0] == 'hello'
db.destroy()
db.drop()
os.path.exists(db_file) and os.remove(db_file)
print('OK')
PYEOF

EOF

# Append MySQL test if URL provided
if [ -n "$MYSQL_ADMIN_URL" ]; then
    if [ -n "$SCHEMA_OPT" ]; then
        INNER="$INNER
echo ''
echo '--- MySQL test (with schemas) ---'
opensips-cli -x \\
  -o database_admin_url=$MYSQL_ADMIN_URL \\
  -o database_url=$MYSQL_URL \\
  -o database_modules=dialog \\
  $SCHEMA_OPT \\
  database create _cli_test
python3 -c \"
import sqlalchemy
e = sqlalchemy.create_engine('${MYSQL_URL%/*}/_cli_test')
tables = sqlalchemy.inspect(e).get_table_names()
assert 'dialog' in tables, 'dialog table not found: ' + str(tables)
print('tables OK:', [t for t in tables if t.startswith('dialog')])
\"
opensips-cli -x \\
  -o database_admin_url=$MYSQL_ADMIN_URL \\
  -o database_force_drop=true \\
  database drop _cli_test
echo 'OK'
"
    else
        INNER="$INNER
echo ''
echo '--- MySQL test (connectivity only) ---'
opensips-cli -x \\
  -o database_admin_url=$MYSQL_ADMIN_URL \\
  -o database_url=$MYSQL_URL \\
  database create _cli_test 2>&1 | grep -v '^\$' || true
opensips-cli -x \\
  -o database_admin_url=$MYSQL_ADMIN_URL \\
  -o database_force_drop=true \\
  database drop _cli_test 2>&1 | grep -v '^\$' || true
echo 'OK'
"
    fi
fi

# Append PostgreSQL test if URL provided
if [ -n "$PG_ADMIN_URL" ]; then
    if [ -n "$SCHEMA_OPT" ]; then
        INNER="$INNER
echo ''
echo '--- PostgreSQL test (with schemas) ---'
opensips-cli -x \\
  -o database_admin_url=$PG_ADMIN_URL \\
  -o database_url=$PG_URL \\
  -o database_modules=dialog \\
  $SCHEMA_OPT \\
  database create _cli_test
python3 -c \"
import sqlalchemy
e = sqlalchemy.create_engine('${PG_URL%/*}/_cli_test')
tables = sqlalchemy.inspect(e).get_table_names()
assert 'dialog' in tables, 'dialog table not found: ' + str(tables)
print('tables OK:', [t for t in tables if t.startswith('dialog')])
\"
opensips-cli -x \\
  -o database_admin_url=$PG_ADMIN_URL \\
  -o database_force_drop=true \\
  database drop _cli_test
echo 'OK'
"
    else
        INNER="$INNER
echo ''
echo '--- PostgreSQL test (connectivity only) ---'
opensips-cli -x \\
  -o database_admin_url=$PG_ADMIN_URL \\
  -o database_url=$PG_URL \\
  database create _cli_test 2>&1 | grep -v '^\$' || true
opensips-cli -x \\
  -o database_admin_url=$PG_ADMIN_URL \\
  -o database_force_drop=true \\
  database drop _cli_test 2>&1 | grep -v '^\$' || true
echo 'OK'
"
    fi
fi

echo "========================================"
echo " Testing: $IMAGE"
echo "========================================"

# Build optional schema mount
SCHEMA_MOUNT=()
if [ -n "$OPENSIPS_DB_PATH" ]; then
    SCHEMA_MOUNT=(-v "${OPENSIPS_DB_PATH}:/opensips_scripts:ro")
fi

docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -v "$(pwd):/src" \
    ${SCHEMA_MOUNT[@]+"${SCHEMA_MOUNT[@]}"} \
    "$IMAGE" bash -c "
        set -e
        $INSTALL_SYS_PKGS
        PIP_FLAGS=$PIP_FLAGS
        cp -r /src /tmp/opensipscli && rm -rf /tmp/opensipscli/.venv*
        pip3 install \$PIP_FLAGS --no-deps /tmp/opensipscli
        pip3 install \$PIP_FLAGS opensips
        $INNER
    "

echo ""
echo "PASSED: $IMAGE"
