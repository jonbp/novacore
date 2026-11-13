ARG PHP_VERSION=8.4
FROM php:${PHP_VERSION}-fpm

ARG UID=1000
ARG GID=1000

# WP-CLI's release and its checksum, from the .sha256 file on the release at
# https://github.com/wp-cli/wp-cli/releases. Change both together.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA256=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c

# install-php-extensions picks the right extension versions for each PHP
# release (e.g. Xdebug 3.1 on PHP 7.4).
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/

# PHP 7.4 and 8.0 are built on Debian bullseye, which now lives on the archive.
RUN if grep -q bullseye /etc/os-release; then \
        printf 'deb http://archive.debian.org/debian %s main\n' \
            bullseye bullseye-updates > /etc/apt/sources.list \
        && echo 'deb http://archive.debian.org/debian-security bullseye-security main' >> /etc/apt/sources.list \
        && rm -f /etc/apt/sources.list.d/*; \
    fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends git unzip less mariadb-client socat openssh-client rsync \
    && rm -rf /var/lib/apt/lists/* \
    && install-php-extensions \
        bcmath exif gd imagick intl mysqli opcache pcntl pdo_mysql redis soap zip \
        xdebug \
        @composer \
    && curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA256}  /usr/local/bin/wp" | sha256sum -c --quiet - \
    && chmod +x /usr/local/bin/wp

# Run PHP as your host user so files it writes stay yours.
RUN groupmod -o -g "${GID}" www-data \
    && usermod -o -u "${UID}" -g "${GID}" www-data \
    && chown www-data:www-data /var/www

# Mailpit's sendmail, which PHP's mail() uses to hand messages to Mailpit.
COPY --from=axllent/mailpit:v1 /mailpit /usr/local/bin/mailpit

COPY conf.d/ /usr/local/etc/php/conf.d/
COPY entrypoint.sh /usr/local/bin/novacore-entrypoint

WORKDIR /var/www/sites

ENTRYPOINT ["novacore-entrypoint"]
CMD ["php-fpm"]
