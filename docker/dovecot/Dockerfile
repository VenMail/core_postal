FROM dovecot/dovecot:2.3

ARG MAIL_ROOT=/mail
ARG MAIL_VERSION=v1
ENV MAILDIR_ROOT=${MAIL_ROOT}/${MAIL_VERSION}

# Install additional packages
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl bash \
  && rm -rf /var/lib/apt/lists/*

# Create vmail user and group
RUN groupadd -g 5000 vmail \
  && useradd -r -u 5000 -g vmail -s /usr/sbin/nologin -d ${MAIL_ROOT} vmail

# Create necessary directories
RUN mkdir -p ${MAILDIR_ROOT} \
  && mkdir -p /var/lib/dovecot/sieve \
  && mkdir -p /etc/dovecot \
  && chown -R vmail:vmail ${MAIL_ROOT} \
  && chown -R vmail:vmail /var/lib/dovecot

# Copy configuration files
COPY conf.d/ /etc/dovecot/conf.d/

# Create default SSL certificate (self-signed for development)
RUN openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" \
    -keyout /etc/ssl/private/dovecot.key \
    -out /etc/ssl/certs/dovecot.crt && \
    chmod 600 /etc/ssl/private/dovecot.key && \
    chmod 644 /etc/ssl/certs/dovecot.crt

# Create quota warning script
RUN echo '#!/bin/bash' > /usr/local/bin/quota-warning.sh \
  && echo 'echo "Quota warning: $1% for user $2"' >> /usr/local/bin/quota-warning.sh \
  && chmod +x /usr/local/bin/quota-warning.sh

# Copy startup script
COPY start.sh /usr/local/bin/start.sh
RUN sed -i 's/\r$//' /usr/local/bin/start.sh \
  && chmod +x /usr/local/bin/start.sh

# Copy user management script
COPY add_user.sh /usr/local/bin/add_user.sh
RUN sed -i 's/\r$//' /usr/local/bin/add_user.sh \
  && chmod +x /usr/local/bin/add_user.sh

# Create a sample user file (you'll need to populate this with actual users)
RUN install -o vmail -g vmail -m 0600 -D /dev/null /etc/dovecot/users \
  && printf '%s\n' "test@example.com:{SHA512-CRYPT}$6$rounds=5000$salt$hash:5000:5000::${MAILDIR_ROOT}/example.com/test:/bin/false" > /etc/dovecot/users

EXPOSE 143 993 110 995

CMD ["/usr/local/bin/start.sh"]