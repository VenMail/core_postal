FROM dovecot/dovecot:2.3

# Install additional packages
RUN apk add --no-cache \
    openssl \
    bash

# Create vmail user and group
RUN addgroup -g 5000 vmail && \
    adduser -D -s /sbin/nologin -u 5000 -G vmail vmail

# Create necessary directories
RUN mkdir -p /mail/v1 && \
    mkdir -p /var/lib/dovecot/sieve && \
    mkdir -p /etc/dovecot/users && \
    chown -R vmail:vmail /mail && \
    chown -R vmail:vmail /var/lib/dovecot

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
RUN echo '#!/bin/bash' > /usr/local/bin/quota-warning.sh && \
    echo 'echo "Quota warning: $1% for user $2"' >> /usr/local/bin/quota-warning.sh && \
    chmod +x /usr/local/bin/quota-warning.sh

# Copy startup script
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Copy user management script
COPY add_user.sh /usr/local/bin/add_user.sh
RUN chmod +x /usr/local/bin/add_user.sh

# Create a sample user file (you'll need to populate this with actual users)
RUN echo "test@example.com:{SHA512-CRYPT}$6$rounds=5000$salt$hash:5000:5000::/mail/v1/example.com/test:/bin/false" > /etc/dovecot/users

# Set proper permissions
RUN chown -R vmail:vmail /etc/dovecot/users

EXPOSE 143 993 110 995

CMD ["/usr/local/bin/start.sh"] 