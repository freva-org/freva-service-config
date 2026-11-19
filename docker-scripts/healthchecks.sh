#!/usr/bin/env bash

# Perform a healthcheck for the specified service.
set -o nounset -o pipefail -o errexit

SERVICE=${SERVICE:-}

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Perform a healthcheck for a Freva service.

Options:
  -s, --service <name>   Name of the service (mongo, mysql, postgres, redis, solr, ...)
  -t, --test             Start the service in test mode
  -h, --help             Show this help message and exit
EOF
}


#  Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--service)
      SERVICE="$2"
      shift 2
      ;;
    -t|--test)
      TEST=true
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      print_help
      exit 1
      ;;
  esac
done


if [ "${TEST:-}" ]; then
    start-service $SERVICE &
    PID=$!
    sleep 10
    trap "kill -9 $PID &> /dev/null || true" EXIT
fi

case "$SERVICE" in
    solr)
        solr status >/dev/null 2>&1
        ;;
    mysql)
        if [ -f "/tmp/mysqld.pid" ];then
            read mysqld_pid < "/tmp/mysqld.pid"
            if kill -0 $mysqld_pid 2>/dev/null ; then
                exit 0
            fi
        fi
        echo "MySQL server not running"
        exit 1
        ;;
    mongo)
        MONGO_DB=${API_MONGO_DB:-search_stats}
        echo "import pymongo" > /tmp/test.py
        echo "" >> /tmp/test.py
        echo "dbs = pymongo.MongoClient('mongodb://$API_MONGO_USER:$API_MONGO_PASSWORD@localhost:27017?timeoutMS=2000').list_database_names()" >> /tmp/test.py
        cat /tmp/test.py
        python /tmp/test.py
        ;;
    redis)
        if [ -f "/tmp/redis-server-${REDIS_PORT:-6379}.pid" ];then
            read redis_pid < "/tmp/redis-server-${REDIS_PORT:-6379}.pid"
            if kill -0 $redis_pid 2>/dev/null ; then
                exit 0
            fi
        fi
        echo "Redis-server not running"
        exit 1

        if ! pgrep -x redis-server > /dev/null; then
            exit 1
        fi
        redis-cli ping | grep -q PONG
        ;;
    nginx)
        config=$(find /tmp -type f -name nginx.conf)
        cat $config
        nginx -t -c $config
        curl -s https://localhost:${NGINX_PORT:-443}/ --insecure || exit 1
        ;;
    versitygw)
        command -v versitygw >/dev/null 2>&1 || { echo "versitygw not found"; exit 1; }
        versitygw --version >/dev/null 2>&1 || { echo "versitygw not runnable"; exit 1; }
        ;;
    postgres)
        # Patroni is there, and a PostgreSQL that takes connections and has
        # pgvector. The checks run as the database user (peer auth).
        PG_UID=${POSTGRES_UID:-999}
        as_postgres() { setpriv --reuid="$PG_UID" --regid="$PG_UID" --init-groups "$@"; }
        patroni --version
        postgres --version
        for _ in $(seq 1 30); do
            as_postgres pg_isready -h /tmp -q && break
            sleep 1
        done
        as_postgres pg_isready -h /tmp
        as_postgres psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -tAc \
            "CREATE EXTENSION IF NOT EXISTS vector; SELECT 'pgvector ' || extversion FROM pg_extension WHERE extname = 'vector'; SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector;"
        ;;
    mlflow)
    mlflow --version

    python - <<'PY'
import mlflow
import mlflow_oidc_auth
import boto3
import psycopg

print("MLflow:", mlflow.__version__)
print("MLflow imports OK")
print("OIDC plugin imports OK")
print("S3 support imports OK")
print("PostgreSQL support imports OK")
PY
    ;;
    *)
        echo "❌ Unknown service: $SERVICE" >&2
        exit 1
        ;;
esac
