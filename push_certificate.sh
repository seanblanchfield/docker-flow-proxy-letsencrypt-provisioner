#!/usr/bin/env bash

# Deploy hook script used by certbot. See https://certbot.eff.org/docs/using.html#certbot-commands
# 
# The shell variable $RENEWED_LINEAGE will point to the config live subdirectory (for example,
# "/etc/letsencrypt/live/example.com") containing the new certificates and keys.
# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
RETRY_PERIOD=5

# Concatenate certificates
printf "Sending certificate for $RENEWED_LINEAGE to $PROXY_ADDRESS\n"
cd $RENEWED_LINEAGE
cert_name="${RENEWED_LINEAGE##*/}.combined.pem"
cat cert.pem chain.pem privkey.pem > $RENEWED_LINEAGE/$cert_name
# Send to proxy
cmd="curl --silent --write-out "%{http_code}" -XPUT --data-binary @$RENEWED_LINEAGE/$cert_name http://$PROXY_ADDRESS:8080/v1/docker-flow-proxy/cert?certName=$cert_name&distribute=true"

# Wait for proxy (or proxies) to be available
while [[ $($cmd) != "200" ]]; do
    printf "${RED}Error sending certificate. Will retry in $RETRY_PERIOD seconds. ${NC}\nCommand was:\n$cmd\n"
    sleep $RETRY_PERIOD
done
printf "${GREEN}Certificate for $RENEWED_LINEAGE sent successfully.${NC}\n"
