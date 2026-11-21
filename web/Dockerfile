# ZTF alert archive website: the landing page and the directory listings of
# /alerts/public and /alerts/partnership. The tarballs and the htpasswd file
# are bind-mounted at runtime (compose.yaml); nothing here is a secret.
FROM docker.io/library/httpd:2.4

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

# The container runs as the service account, not root, so it must own the
# directory Apache writes its pid file to.
RUN groupadd -g ${SVC_GID} ${SVC_USER} 2>/dev/null || true && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} 2>/dev/null || true && \
    chown -R ${SVC_UID}:${SVC_GID} /usr/local/apache2/logs

COPY htdocs/      /srv/htdocs/
COPY fancy-index/ /srv/fancy-index/
COPY conf/        /usr/local/apache2/conf/ztf/

RUN sed -i 's/^Listen 80$/#Listen 80/' /usr/local/apache2/conf/httpd.conf && \
    echo 'Include conf/ztf/httpd.conf' >> /usr/local/apache2/conf/httpd.conf && \
    SERVER_NAME=build-check httpd -t

EXPOSE 8080

CMD ["httpd-foreground"]
