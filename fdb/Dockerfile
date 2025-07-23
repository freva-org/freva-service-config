FROM ubuntu:latest
USER root
ARG SERVICE
LABEL org.freva.service="$SERVICE"
LABEL org.opencontainers.image.authors="DRKZ-CLINT"
LABEL org.opencontainers.image.source="https://github.com/freva-org/freva-service-config"
ENV    PYTHONUNBUFFERED=1 \
       IN_DOCKER=1 \
       SERVICE=${SERVICE} \
       DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    fdb5 \
    libfdb5-dev 

WORKDIR /fdb-test
COPY config /fdb-test/config
COPY data /fdb-test/data
ENV FDB5_CONFIG_FILE=/fdb-test/config/test-fdb.cfg

RUN fdb-info --all

## test write and read
RUN fdb-write /fdb-test/data/foo.grib
RUN fdb-dump --all
