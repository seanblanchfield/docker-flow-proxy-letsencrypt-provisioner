#!/usr/bin/env bash

# This script figures out what domains are being served by docker-flow-proxy, and then uses certbot to get certificates for them.
# 
# Care is taken to avoid unnecessarily reaching LetsEncrypt's rate limits (https://letsencrypt.org/docs/rate-limits/)
# The current rate limits:
# - "Certificates per Registered Domain" limit of 50 per week
# - "Names per Certificate" limit of 100 subdomains per week, (i.e., subdomains concatenated into a single certificate).
# - "Duplicate Certificate" limit of 5 duplicated certificates unnecessarily renewed each week
#
# We do a certbot dry run on each domain/subdomain to validate that it is legal and that a cert can be issued for it.
# Then for each top-level domain we create a combined certificate that contains both the TLD and all validated subdomains.

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Common certbot arguments
certbot_args=("--no-self-upgrade" "--no-bootstrap" "--webroot" "--webroot-path" "/var/www/" "--non-interactive" "--expand" "--keep-until-expiring" "--email" "$CERTBOT_EMAIL" "--agree-tos" "--preferred-challenges" "http-01" "--rsa-key-size" "4096" "--redirect" "--hsts" "--staple-ocsp")

# Optionally set the --staging argument.
if [[ "$(echo $STAGING | tr '[:upper:]' '[:lower:]')" =~ true ]]; then
    printf "${GREEN}Using LetsEncrypt Staging environment.${NC}\n";
    certbot_args+=("--staging");
fi

# Parse the EXCLUDE_DOMAINS env var.
EXCLUDE_DOMAINS=$(echo $EXCLUDE_DOMAINS | tr "," " ") 

function sort_by_length() {
    echo $1 | tr " " "\n" | awk '{ print length(),$0}' | sort -n | cut -d" " -f2- | xargs
}

function get_domains() {
    # Make a array of domains served by docker-flow-proxy
    all_domains=( $(curl -si http://$PROXY_ADDRESS:8080/v1/docker-flow-proxy/config | grep "acl domain_" | sed -e 's/^[[:space:]]*acl domain.* -i //') )
    # Filter out any domains that should be excluded.
    domains=()
    for domain in "${all_domains[@]}"; do
        if ! [[ " $EXCLUDE_DOMAINS " =~ " $domain " ]]; then
            domains+=( $domain )
        fi
    done
    # Rearrange so that subdomains are grouped together in comma-separated lists with the top-level domain as the first item in the list.
    all_subdomains=()
    for domain in "${domains[@]}"; do
        if [[ " ${all_subdomains[@]} " =~ " $domain " ]]; then
            # We have already processed $domain as a subdomain of another domain, so skip it.
            continue
        fi
        subdomains=()
        for other_domain in "${domains[@]}"; do
            if [[ "$other_domain" != "$domain" && $other_domain =~ \.$domain$ ]]; then
                # $other_domain is a subdomain of $domain
                subdomains+=($other_domain)
                all_subdomains+=($other_domain)
            fi
        done
        subdomains=( $(sort_by_length "${subdomains[*]}") )
        echo "$domain ${subdomains[@]}"
    done
}


# Now iterate groups of domains and get certs where necessary.
echo "$(get_domains)" | while read -r subdomains ; do
    # Convert to array
    subdomains=( $subdomains )

    # The first item should be the top-level domain (i.e. the shortest domain).
    tld=${subdomains[0]}
    printf "${GREEN}Processing certificate for $tld.${NC}\n";

    # Look for any existing certificate and get a list of domains covered by it.
    existing_cert=/etc/letsencrypt/live/$tld/$tld.combined.pem
    existing_cert_domains=""
    if [ -e $existing_cert ]; then
        # Parse certificate to get a sorted list of current domains covered by it.
        existing_cert_domains=$(openssl x509 -text < $existing_cert  | grep DNS | sed 's/\s*DNS:\([a-z0-9.\-]*\)[,\s]\?/\1\n/g' | xargs)
        existing_cert_domains=$(sort_by_length "$existing_cert_domains")
    fi

    if [[ "${subdomains[*]}" == "$existing_cert_domains" ]]; then
        printf "Skipping registration of $tld, because existing certificate was found.\n"
        # Docker-flow-proxy should be configured with a volume mounted at "/certs", so that
        # its certificate state persists across restarts. But for good measure, let's give it a fresh copy of
        # any certs we find during our start up.
        RENEWED_LINEAGE=/etc/letsencrypt/live/${tld} /certbot_deploy_hook.sh
        continue
    else
        # If we get this far, then $subdomains contains new domains to be registered.

        # Do a dry run against each domain to check for potential issues, and keep track of the validated domains.
        validated_subdomains="";
        for subdomain in "${subdomains[@]}"; do
            # --dry-run uses the certbot staging environment, and does not persist any changes to disk.
            # This allows us to verify that we control the domain and everything is valid about it, before
            # attempting to generate certs against the rate limited LetsEncrypt production servers.
            if certbot certonly --dry-run "${certbot_args[@]}" -d "$subdomain" ; then
                printf "${GREEN}Domain $subdomain successfully validated.${NC}\n"
                validated_subdomains="$validated_subdomains -d $subdomain"
            else
                printf "${RED}Validation of $subdomain failed, and will be skipped.${NC}\n"
            fi
        done
    
        # Only proceed if we have at least one valid domain.
        if [ -n "$validated_subdomains" ]; then
            # Use of the deploy hook here should not only mean that the cert will be pushed to docker-flow-proxy when deployed,
            # but that certbot will re-invoke the deploy hook whenever it renews this cert in the future. This is an undocumented feature
            # discussed here: https://github.com/certbot/certbot/issues/6180#issuecomment-539233867
            cmd="certbot certonly ${certbot_args[@]} --cert-name ${tld} $validated_subdomains --deploy-hook /certbot_deploy_hook.sh"
            if $cmd ; then
                printf "${GREEN}Certificate for domain $tld successfully saved.${NC}\n"
            else
                printf "${RED}Generation of cert for $tld failed.${NC}\nFailed command was: $cmd\n"
            fi
        else
            printf "${RED}Skipping cert for $tld, which has no validated domains.${NC}\n"
        fi
    fi
    
done

