Docker Flow: Let's Encrypt Provisioner
==================

* [Introduction](#introduction)
* [Comparison](#comparison)
* [How it works](#how-it-works)
* [Usage](#usage)

## Introduction
This is a docker image that automatically provides Let's Encrypt certificates to Docker Flow Proxy. 

It is largely inspired by the similar projects [Docker Flow Proxy Letsencrypt](https://github.com/n1b0r/docker-flow-proxy-letsencrypt) by [n1b0r](https://github.com/n1b0r/) and [Docker Flow: Let's Encrypt](https://github.com/hamburml/docker-flow-letsencrypt) by [Michael Hamburger](https://github.com/hamburml), but provides some improvements.

## Comparison with alternatives

[n1b0r](https://github.com/n1b0r/)'s version is implemented in Python, and acts as a transparent proxy that sits between Docker Flow Listener and Docker Flow Proxy. This allows it to hear about new services that Docker Flow Listener discovers, and respond by running `certbot` commands to generate appropriate certificates, which it then passes to Docker Flow Proxy as Docker secrets, before forwarding the original Docker Flow Listener notification to the proxy.
I found the following issues with this project:
* It is not well maintained.
* To distribute certs to Docker Flow Proxy it requires access to the Docker socket, which is a serious security risk, especially since the container is accessible via the Internet.
* Because it proxies communication between Docker Flow Proxy and Docker Flow Listener,  any issues with it could severely disrupt all other services.
* When it misbehaved I found myself hitting Let's Encrypt rate limits.

[Michael Hamburger](https://github.com/hamburml)'s project is implemented in Bash, and runs `certbot` in standalone mode to generate certificates for domains passed to it explicitly via environment variables, and then pushes those certificates into Docker Flow Proxy via its API. It is significantly more simple than n1b0r's version, which seems to make it more reliable. It also takes great care to respect Let's Encrypt's rate limits, which is great. Another big benefit is that if it crashes, it does not affect the operation of Docker Flow Proxy itself.

The downsides are:
* A race condition exists when it runs in standalone mode, when `Certbot` starts its own HTTP server on port 80 to perform domain verification. It takes some time for Docker Flow Proxy to sense that the `Certbot`'s service has come up, and until this happens, Let's Encrypt's challenges will not succeed. In practice, I found that certificate generation would occasionally fail due for this reason.
* It was a slight pain to have to configure each domain that a cert should be generated for.

## How it works

This project draws a lot of inspiration from the best parts of [Michael Hamburger](https://github.com/hamburml)'s [Docker Flow: Let's Encrypt](https://github.com/hamburml/docker-flow-letsencrypt), especially in terms of simple implementation in Bash and careful attention given to rate limits. However, instead of running `certbot` in standalone mode (which launches a temporary web server), it instead runs a separate long-lived webserver process (Python3's `http.server`, given that Python3 is already installed as a dependency of Certbot), and then runs `certbot` in "webroot" mode (in which it temporarily places it challenge responses into the www directory). This approach avoids the race condition problem discussed above by ensuring that the service remains accessible to the internet.

In addition, it automatically reads domains from Docker Flow Proxy's API (instead of requiring them to be explicitly configured). It will automatically get certs for each domain that Docker Flow Proxy serves, unless the domain is explicitly excluded via the `EXCLUDED_DOMAINS` env variable (this can be used to exclude domains that have extended validation certificates, for example).

On startup it configures a cronjob to run every twelve hours to renew any certificates that are in need of renewal. This cronjob is offset by a random interval, to help level out any load created on Let's Encrypt.

Whenever a certificate is registered or renewed by certbot, a deploy hook script is run, which uploads the certificate to Docker Flow Proxy.

## Usage
Run as a service within your Docker swarm, alongside Docker Flow Proxy. You should ensure that there is just one replica of it, that it is constrained to run on a single host, and that it is on the same network as Docker Flow Proxy.

You should mount a volume at `/etc/letsencrypt`, where certificates from Let's Encrypt will be saved. If you fail to do this, new certificates will be created each time the service starts up, which may cause you to hit Let's Encrypt's [rate limits](https://letsencrypt.org/docs/rate-limits/) and get banned for a week.

The following configuration options are available as environment variables:
* `CERTBOT_EMAIL`  The email address used to register certificates with Let's Encrypt.
* `PROXY_ADDRESS`  Docker Flow Proxy's hostname on the current network that the container can connect to.
* `STAGING` Set to "false" to disable use of Let's Encrypt's staging environment. (default: true)
* `EXCLUDE_DOMAINS` Set to a comma-delimited list of domains that should be ignored. Use this to avoid generating Let's Encrypt certificates for domains that you are manually managing certificates for (e.g., any certificates that you are manually providing to Docker Flow Proxy via [Docker Secrets](https://proxy.dockerflow.com/certs/#adding-certificates-as-docker-secrets)).



``` yaml
version: '3.7'

services:
  
  letsencrypt-provisioner:
    build: .
    volumes:
      - /tmp:/etc/letsencrypt/
    environment:
        - CERTBOT_EMAIL=your@email.address
        - PROXY_ADDRESS=docker-flow-proxy
        - STAGING=false
        - EXCLUDE_DOMAINS="somedomain2.net,otherdomain3.org"
    deploy:
      placement:
        constraints:
          - "node.id==<NODE ID>"
      labels:
        - com.df.aclName=__acme_letsencrypt_companion # arbitrary aclName to make sure it's on top on HAProxy's list
        - com.df.notify=true
        - com.df.distribute=true
        # The LetsEncrypt HTTP-01 challenge path:
        # https://letsencrypt.org/docs/challenge-types/
        - com.df.servicePath=/.well-known/acme-challenge
        - com.df.port=80

```