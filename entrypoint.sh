#!/usr/bin/env bash
set -e 

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
RETRY_PERIOD=5

printf "${GREEN}LetsEncrypt Provisioner is starting at $(date).${NC}\n";

# Create a deploy hook file that certbot can use to push certs into docker-flow-proxy
cat << EOF > /certbot_deploy_hook.sh
#!/usr/bin/env bash

export PROXY_ADDRESS=$PROXY_ADDRESS
/push_certificate.sh
EOF
chmod a+x /certbot_deploy_hook.sh

RENEW_COMMAND="certbot renew --no-bootstrap --no-self-upgrade --deploy-hook /certbot_deploy_hook.sh "

# Wait for proxy to be available
while [[ $(curl -s http://$PROXY_ADDRESS:8080/v1/docker-flow-proxy/ping  --output /dev/null --write-out "%{http_code}") != "200" ]]; do
    printf "${RED}Could not connect to $proxy_addr. Will retry in $retry_period seconds.${NC}"
    sleep $RETRY_PERIOD
done

# Start web server
printf "${GREEN}Starting web server.${NC}\n";
python3 -m http.server 80 --bind 0.0.0.0 --directory /var/www/ &
PID=$!

# Create a file to use to test connectivity
ping_path=.well-known/acme-challenge/ping
mkdir -p /var/www/$(dirname $ping_path)
echo pong > /var/www/$ping_path
# Pick a domain at random from the domains that docker flow proxy is serving
random_domain=$(curl -si http://$PROXY_ADDRESS:8080/v1/docker-flow-proxy/config | grep "acl domain_" | sed -e 's/^[[:space:]]*acl domain.* -i //' | shuf -n 1)
test_url=http://$random_domain/$ping_path
while [[ $(curl -s $test_url) != "pong" ]]; do
    printf "${RED}Could not confirm own availability via internet. Will retry in $retry_period seconds.${NC}"
    sleep $RETRY_PERIOD
done


# Set up cron job to renew certs
CRON_MIN=$(($RANDOM % 60))
CRON_HOUR=$(($RANDOM % 24))
printf "$CRON_MIN $CRON_HOUR * * * $RENEW_COMMAND\n\n" > /etc/cron.d/renew

service cron start
crontab /etc/cron.d/renew

# Renew any existing certs (this will only actually renew those due to expire soon).
printf "${GREEN}Renewing any existing certificates.${NC}\n";
$RENEW_COMMAND

# Generate any new certificates required
/generate_certificates.sh

clean_up() {
    kill -TERM $PID
    trap - TERM
    exit 0
}
trap clean_up TERM
wait $PID
