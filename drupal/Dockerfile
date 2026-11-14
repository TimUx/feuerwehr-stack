FROM drupal:11.4.12-php8.4-apache-bookworm@sha256:7e592e1f8ac25b5f5c38a1d7c41b9013c053ce486f32b6909a88314cb9ab73f7

RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists

COPY composer.json composer.lock /opt/drupal/
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader \
    && composer check-platform-reqs --no-dev \
    && chown -R root:root /opt/drupal \
    && mkdir -p /var/drupal/private \
    && mkdir -p web/sites/default/files \
    && chown www-data:www-data /var/drupal/private web/sites/default/files

COPY settings.php /opt/drupal/web/sites/default/settings.php
COPY configure.php /opt/drupal/configure.php
COPY entrypoint.sh /usr/local/bin/feuerwehr-drupal
RUN php -l web/sites/default/settings.php && php -l configure.php \
    && sh -n /usr/local/bin/feuerwehr-drupal \
    && chmod 0755 /usr/local/bin/feuerwehr-drupal

ENTRYPOINT ["feuerwehr-drupal"]
CMD ["apache2-foreground"]
