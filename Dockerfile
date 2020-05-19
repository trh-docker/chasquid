# Build image
FROM quay.io/spivegin/gitonly:latest AS git

FROM quay.io/spivegin/golang:v1.14.1 AS builder
WORKDIR /opt/src/src/github.com/albertito/

RUN ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa && git config --global user.name "quadtone" && git config --global user.email "quadtone@txtsme.com"
COPY --from=git /root/.ssh /root/.ssh
RUN ssh-keyscan -H github.com > ~/.ssh/known_hosts &&\
    ssh-keyscan -H gitlab.com >> ~/.ssh/known_hosts &&\
    ssh-keyscan -H gitea.com >> ~/.ssh/know_hosts

#COPY --from=gover /opt/go /opt/go
ENV deploy=c1f18aefcb3d1074d5166520dbf4ac8d2e85bf41 \
    GO111MODULE=on \
    GOPROXY=direct \
    GOSUMDB=off \
    GOPRIVATE=sc.tpnfc.us
    # GIT_TRACE_PACKET=1 \
    # GIT_TRACE=1 \
    # GIT_CURL_VERBOSE=1\
RUN git config --global url.git@github.com:.insteadOf https://github.com/ &&\
    git config --global url.git@gitlab.com:.insteadOf https://gitlab.com/ &&\
    git config --global url.git@gitea.com:.insteadOf https://gitea.com/ &&\
    git config --global url."https://${deploy}@sc.tpnfc.us/".insteadOf "https://sc.tpnfc.us/"

RUN git clone https://github.com/albertito/chasquid.git && cd chasquid
RUN go get -d ./...
RUN make all &&\
    chmod +x chasquid chasquid-util dovecot-auth-cli mda-lmtp smtp-check spf-check

FROM quay.io/spivegin/tlmbasedebian
RUN mkdir /opt/bin
# Make debconf/frontend non-interactive, to avoid distracting output about the
# lack of $TERM.
ENV DEBIAN_FRONTEND noninteractive

# Install the packages we need.
# This includes chasquid, which sets up good defaults.
RUN apt-get update -q
RUN apt-get install -y -q \
	chasquid \
	dovecot-lmtpd dovecot-imapd dovecot-pop3d \
	dovecot-sieve dovecot-managesieved \
	acl sudo certbot

# Copy the binaries. This overrides the debian packages with the ones we just
# built above.
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/chasquid /usr/bin/
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/chasquid-util /usr/bin/
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/smtp-check /usr/bin/
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/mda-lmtp /usr/bin/
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/dovecot-auth-cli /usr/bin/
COPY --from=builder /opt/src/src/github.com/albertito/chasquid/spf-check /usr/bin/
# Let chasquid bind privileged ports, so we can run it as its own user.
RUN setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/chasquid
# Copy docker-specific configurations.
COPY files/dovecot/dovecot.conf /etc/dovecot/dovecot.conf
COPY files/chasquid/chasquid.conf /etc/chasquid/chasquid.conf

# Copy utility scripts.
COPY files/bash/add-user.sh /
COPY files/bash/entrypoint.sh /

# Store emails and chasquid databases in an external volume, to be mounted at
# /data, so they're independent from the image itself.
VOLUME /data

# Put some directories where we expect persistent user data into /data.
RUN rmdir /etc/chasquid/domains/
RUN ln -sf /data/chasquid/domains/ /etc/chasquid/domains
RUN rm -rf /etc/letsencrypt/
RUN ln -sf /data/letsencrypt/ /etc/letsencrypt

# Give the chasquid user access to the necessary configuration.
RUN setfacl -R -m u:chasquid:rX /etc/chasquid/
RUN mv /etc/chasquid/certs/ /etc/chasquid/certs-orig
RUN ln -s /etc/letsencrypt/live/ /etc/chasquid/certs


# NOTE: Set AUTO_CERTS="example.com example.org" to automatically obtain and
# renew certificates upon startup, via Letsencrypt. You're agreeing to their
# ToS by setting this variable, so please review them carefully.
# CERTS_EMAIL should be set to your email address so letsencrypt can send you
# critical notifications.

# Custom entry point that does some configuration checks and ensures
# letsencrypt is properly set up.
# ENTRYPOINT ["/entrypoint.sh"]
CMD ["/entrypoint.sh"]
# chasquid: SMTP, submission, submission+tls.
EXPOSE 25 465 587

# dovecot: POP3s, IMAPs, managesieve.
EXPOSE 993 995 4190

# http for letsencrypt/certbot.
EXPOSE 80 443

