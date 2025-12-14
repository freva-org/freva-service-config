#!/usr/bin/env bash

# Perform a healthcheck for the specified service.
set -o nounset -o pipefail -o errexit

SERVICE=${SERVICE:-}

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Perform a healthcheck for a Freva service.

Options:
  -s, --service <name>   Name of the service (mongo, mysql, redis, solr)
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
    *)
        echo "❌ Unknown service: $SERVICE" >&2
        exit 1
        ;;
esac
