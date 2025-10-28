FROM ruby:2.6-buster AS base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list \
  && sed -i 's|security.debian.org|archive.debian.org|g' /etc/apt/sources.list \
  && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
  software-properties-common dirmngr apt-transport-https \
  && apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc' \
  && add-apt-repository 'deb [arch=amd64,arm64,ppc64el] https://mirrors.xtom.nl/mariadb/repo/10.6/debian buster main' \
  && (curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -) \
  && (echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list) \
  && (curl -sL https://deb.nodesource.com/setup_16.x | bash -) \
  && rm -rf /var/lib/apt/lists/*

# Install main dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  build-essential  \
  netcat \
  curl \
  libmariadb-dev \
  libmariadb-dev-compat \
  nano \
  nodejs

RUN setcap 'cap_net_bind_service=+ep' /usr/local/bin/ruby

# Configure 'postal' to work everywhere (when the binary exists
# later in this process)
ENV PATH="/opt/postal/app/bin:${PATH}"

# Setup an application
RUN useradd -r -d /opt/postal -m -s /bin/bash -u 999 postal
USER postal
RUN mkdir -p /opt/postal/app /opt/postal/config
WORKDIR /opt/postal/app

# Install bundler
RUN gem install bundler -v 2.1.4 --no-doc

# Install the latest and active gem dependencies and re-run
# the appropriate commands to handle installs.
COPY --chown=postal Gemfile Gemfile.lock ./
RUN bundle install -j 4

# Copy the application (and set permissions)
COPY ./docker/wait-for.sh /docker-entrypoint.sh
COPY --chown=postal . .
RUN find bin -maxdepth 1 -type f -exec sed -i 's/\r$//' {} +

# Export the version
ARG VERSION=unspecified
RUN echo $VERSION > VERSION

# Set the path to the config
ENV POSTAL_CONFIG_ROOT=/config

# Set the CMD
ENTRYPOINT [ "/docker-entrypoint.sh" ]
CMD ["postal"]

# ci target - use --target=ci to skip asset compilation
FROM base AS ci

# prod target - default if no --target option is given
FROM base AS prod

RUN POSTAL_SKIP_CONFIG_CHECK=1 RAILS_GROUPS=assets bundle exec rake assets:precompile
RUN touch /opt/postal/app/public/assets/.prebuilt
