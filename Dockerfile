FROM ubuntu:latest

RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get -y install \
        cron \
        curl \
        certbot \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 

# Add shell script and grant execution rights
ADD entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ADD push_certificate.sh /push_certificate.sh
RUN chmod +x /push_certificate.sh
ADD generate_certificates.sh /generate_certificates.sh
RUN chmod +x /generate_certificates.sh

RUN mkdir -p /var/www
VOLUME [ "/etc/letsencrypt" ]

ENV EXCLUDE_DOMAINS=""
ENV CERTBOT_EMAIL="you@example.com"
ENV PROXY_ADDRESS="docker-flow-proxy"
ENV STAGING="true"

EXPOSE 80

# Run the command on container startup
ENTRYPOINT [ "/entrypoint.sh" ]
