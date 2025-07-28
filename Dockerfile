FROM docker.io/mambaorg/micromamba
USER root
ARG SERVICE
ARG VERSION
LABEL org.freva.service="$SERVICE"
LABEL org.opencontainers.image.authors="DRKZ-CLINT"
LABEL org.opencontainers.image.source="https://github.com/freva-org/freva-service-config"
LABEL org.opencontainers.image.version="$VERSION"
ENV    PYTHONUNBUFFERED=1 \
       IN_DOCKER=1 \
       SERVICE=${SERVICE} \
       PATH=/opt/conda/bin:${PATH}


# Install apt packages for system user lookup
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libnss-sss \
        libpam-sss \
        sssd-common \
        sssd-tools && \
    rm -rf /var/lib/apt/lists*

WORKDIR /tmp/app
COPY . ${SERVICE}/build-fdb-source.sh /tmp/app/


RUN set -xue && \
 ls -l /tmp/app/${SERVICE} && ls -l ${SERVICE} && \
 cp docker-scripts/entrypoint.sh /usr/local/bin/ &&\
 chmod +x /usr/local/bin/entrypoint.sh && \
 cp /tmp/app/${SERVICE}/build-fdb-source.sh /usr/local/bin/build-fdb-source.sh || true &&\
 chmod +x /usr/local/bin/build-fdb-source.sh  || true && \
 cp ${SERVICE}/init-${SERVICE} /usr/local/bin/start-service &&\
 mkdir -p /data/{db,logs,config} /backup && \
 cp docker-scripts/healthchecks.sh /usr/local/bin/healthchecks &&\
 cp ${SERVICE}/*.txt /data/config/ 2> /dev/null || true && \
 cp ${SERVICE}/*.xml /data/config/ 2> /dev/null || true && \
 cp ${SERVICE}/*.sql /data/config/ 2> /dev/null || true && \
 cp ${SERVICE}/*.{cfg,schema,grib} /data/config/ 2> /dev/null || true && \
 cp ${SERVICE}/*.{types,j2,html,gif} /data/config/ 2> /dev/null || true && \
 rm -f /data/config/requirements.txt && \
 cp docker-scripts/daily-backup.sh /usr/local/bin/daily-backup &&\
 chmod +x /usr/local/bin/daily-backup &&\
 chmod +x /usr/local/bin/start-service /usr/local/bin/healthchecks

RUN set -eu \
     && for user in sync news uucp irc list lp games gnats ftp man proxy operator talk nobody _apt;do\
       deluser $user 2> /dev/null || true;\
     done \
     && delgroup mambauser || true \
     && rm -rf /home/mambauser || true \
     && delgroup nogroup || true \
     && addgroup --system --gid 65534 nobody || true \
     && adduser \
    --system \
    --uid 65534 \
    --gid 65534 \
    --no-create-home \
    --disabled-password \
    --shell /usr/sbin/nologin \
   nobody

# Install the mamba stuff
RUN  set -eux && \
     micromamba install -c conda-forge -q -y --override-channels -f $SERVICE/requirements.txt && \
     micromamba clean -q -y -i -t -l -f && \
     chmod 1777 -R /data /backup && \
     rm -rf /tmp/app

RUN if [ "$SERVICE" = 'fdb' ]; then apt update -y && apt install -y fdb5 libfdb5-dev; fi 
ENV FDB5_CONFIG_FILE=/data/config/fdb.cfg

WORKDIR /data
CMD ["/usr/local/bin/start-service"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
