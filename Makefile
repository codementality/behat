# ----------------
# Make help script
# ----------------

# Usage:
# Add help text after target name starting with '\#\#'
# A category can be added with @category. Team defaults:
# 	dev-environment
# 	docker
# 	drush

# Output colors
GREEN  := $(shell tput -Txterm setaf 2)
WHITE  := $(shell tput -Txterm setaf 7)
YELLOW := $(shell tput -Txterm setaf 3)
RESET  := $(shell tput -Txterm sgr0)

# Script
HELP_FUN = \
	%help; \
	while(<>) { push @{$$help{$$2 // 'options'}}, [$$1, $$3] if /^([a-zA-Z0-9\-]+)\s*:.*\#\#(?:@([a-zA-Z0-9\-]+))?\s(.*)$$/ }; \
	print "usage: make [target]\n\n"; \
	print "see makefile for additional commands\n\n"; \
	for (sort keys %help) { \
	print "${WHITE}$$_:${RESET}\n"; \
	for (@{$$help{$$_}}) { \
	$$sep = " " x (32 - length $$_->[0]); \
	print "  ${YELLOW}$$_->[0]${RESET}$$sep${GREEN}$$_->[1]${RESET}\n"; \
	}; \
	print "\n"; }

help: ## Show help (same if no target is specified).
	@perl -e '$(HELP_FUN)' $(MAKEFILE_LIST) $(filter-out $@,$(MAKECMDGOALS))

#
# Dev Environment settings
#

include .env

.PHONY: up down stop prune ps shell drush logs help

default: up

DRUPAL_ROOT ?= /var/www/drupal/web

#
# Dev Operations
#
initialize: ##@setup Initialize Drupal installation
	@if [ ! -d "./drupal" ]; then \
		docker-compose up -d --build php db; \
		echo "Creating Drupal installation in drupal directory..."; \
		docker-compose exec -T php /bin/bash -c "cd /var/www; composer create-project drupal-composer/drupal-project:8.x-dev drupal --no-interaction"; \
		docker-compose exec -T php /bin/bash -c "cd /var/www/drupal/web; ../vendor/bin/drush si demo_umami --db-url=mysql://drupal:drupal@db/drupal --account-name=admin --account-pass=drupaladm1n --site-name=\"Umami\" -y"; \
		docker-compose exec -T php /bin/bash -c "chmod a+w /var/www/drupal/web/sites/default/settings.php; cp /var/www/config/drupal/settings.php /var/www/drupal/web/sites/default/settings.php"; \
		cp .env drupal/.env; \
		docker-compose down; \
	fi
	@docker-compose up -d --build
	@docker-compose ps

up: ##@docker Start containers and display status.
	@echo "Starting up containers for $(PROJECT_NAME)..."
	docker-compose pull
	docker-compose up -d --remove-orphans --build
	docker-compose ps

down: stop

stop: ##@docker Stop and remove containers.
	@echo "Stopping containers for $(PROJECT_NAME)..."
	@docker-compose stop

prune: ##@docker Remove containers for project.
	@echo "Removing containers for $(PROJECT_NAME)..."
	@docker-compose down -v

ps: ##@docker List containers.
	@docker ps --filter name='$(PROJECT_NAME)*'

shell: ##@docker Shell into the container. Specify container name.
	docker exec -ti -e COLUMNS=$(shell tput cols) -e LINES=$(shell tput lines) $(shell docker ps --filter name='$(PROJECT_NAME)_php' --format "{{ .ID }}") sh

shell-mysql: ##@docker Shell into mysql container.
	docker exec -ti -e COLUMNS=$(shell tput cols) -e LINES=$(shell tput lines) $(shell docker ps --filter name='$(PROJECT_NAME)_mariadb' --format "{{ .ID }}") sh

drush: ##@docker Run arbitrary drush commands.
	docker exec $(shell docker ps --filter name='$(PROJECT_NAME)_php' --format "{{ .ID }}") drush -r $(DRUPAL_ROOT) $(filter-out $@,$(MAKECMDGOALS)) -v

logs: ##@docker Display log.
	@docker-compose logs -f $(filter-out $@,$(MAKECMDGOALS))

#
# Dev Environment build operations
#
install: ##@dev-environment Configure development environment.
	make down
	make clean
	make up
	if [ ! -f docroot/sites/default/settings.local.php ]; then cp docroot/sites/default/default.settings.local.php docroot/sites/default/settings.local.php; fi
	@make composer-install
	@echo "Pulling database for $(PROJECT_NAME)..."
	make pull-db
	make prep-site
	@echo "Development environment for $(PROJECT_NAME) is ready."
	@make uli

composer-update: ##@dev-environment Run composer update.
	docker-compose exec -T php composer update -n --prefer-dist -v

composer-install: ##@dev-environment Run composer install
	docker-compose exec -T php composer install -n --prefer-dist -v

pull-db: ##@dev-environment Download AND import `database.sql`.
	# change permission for ssh keys before using them to pull the DB.
	chmod 400 .docker/.ssh/id_rsa*
	@echo "Pulling DB from Azure Prod environment"
	docker exec -ti $(PROJECT_NAME)_php sh -c "cd /var/www/html/docroot; drush sql-drop -yv; drush sql-sync @predictiveindex.prod @predictiveindex.local -yv"
	make sanitize-db

import-db: ##@dev-environment Import DB. Use if you dont have access to the server, but have access to DB dump.
	if [ -f .docker/db/database.sql.gz ]; then gunzip .docker/db/database.sql.gz -f; fi
	docker-compose exec -T php bin/drush @predictiveindex.local sql-drop -y
	if command -v pv >/dev/null; then pv .docker/db/database.sql | docker exec -i $(PROJECT_NAME)_mariadb mysql -udrupal -pdrupal drupal; else docker exec -i $(PROJECT_NAME)_mariadb mysql -udrupal -pdrupal drupal < .docker/db/database.sql; fi
	make sanitize-db

sanitize-db: ##@dev-environment Sanitize the database.
	# Sanitize database.
	@echo "Sanitizing database for $(PROJECT_NAME)..."
	docker-compose exec -T php bin/drush @predictiveindex.local sqlsan -y
	# Set admin user password to "password".
	@echo "Admin password is set to 'password'"
	docker-compose exec -T php bin/drush @predictiveindex.local user-password admin --password="password"

prep-site: ##@dev-environment Prepare site for local dev.
	make updb
	make cc-all
	make uli

clean: ##@dev-environment Clean settings files and volumes data.
	chmod 777 docroot/sites/default
	if [ -f docroot/sites/default/settings.local.php ]; then rm docroot/sites/default/settings.local.php; fi
	if [ -f .docker/db/database.sql.gz ]; then rm .docker/db/database.sql.gz; fi
	if [ -f .docker/db/database.sql ]; then rm .docker/db/database.sql; fi
	make down
	docker-compose down --volumes

#
# Drush
#
uli: ##drush Generate login link.
	@docker-compose exec -T php bin/drush @predictiveindex.local --uri=http://predictiveindex.test uli

cc-all: ##drush Drush import configuration.
	docker-compose exec -T php bin/drush @predictiveindex.local cc all

updb: ##drush run database updates.
	docker-compose exec -T php bin/drush @predictiveindex.local updb -yv

update-core: ##drush update Core to the latest version. Use for security updates.
	docker-compose exec -T php bin/drush @predictiveindex.local pm-update drupal -yv

#
# Tests
#
install-tests:
	docker-compose exec -T php composer install -n --prefer-dist
	docker-compose exec -T php bin/phpcs --config-set installed_paths vendor/drupal/coder/coder_sniffer

test:
	@docker-compose exec -T php php -l docroot/sites/all/modules/custom
	@docker-compose exec -T php php -l docroot/sites/all/modules/features
	@docker-compose exec -T php bin/phpcs --standard=Drupal tests docroot/sites/all/modules/custom --ignore=*.css,*.min.js,*features.*.inc --exclude=Drupal.InfoFiles.AutoAddedKeys

phpcs:
	docker exec $(shell docker ps --filter name='$(PROJECT_NAME)_php' --format "{{ .ID }}") bin/phpcs --standard=Drupal tests docroot/sites/all/modules/custom --ignore=*.css,*.min.js,*features.*.inc --exclude=Drupal.InfoFiles.AutoAddedKeys

behat:
	docker-compose exec -T php bin/drush @predictiveindex.local cc drush -y
	docker-compose exec -T php bin/behat -c tests/behat.yml --colors --tags=~@failing -f pretty -v

behat-wip:
	docker-compose exec -T php bin/drush @predictiveindex.local cc drush -y
	docker-compose exec -T php bin/behat -c tests/behat.yml --colors --tags=@wip -f pretty -v

#
# Travis
#
travis-install: ##@travis-environment Configure Travis build environment.
	make up
	if [ ! -f docroot/sites/default/settings.local.php ]; then cp docroot/sites/default/default.settings.local.php docroot/sites/default/settings.local.php; fi
	make composer-install
	@echo "Pulling database for $(PROJECT_NAME)..."
	if [ -f .docker/db/database.sql.gz ]; then rm .docker/db/database.sql.gz; fi
	# change permission for ssh keys before using them to pull the DB.
	chmod 400 .docker/.ssh/id_rsa*
	@echo "Pulling seed DB from Azure prod environment"
	scp -o "StrictHostKeyChecking no" -i .docker/.ssh/id_rsa promet@drupal.predictiveindex.com:../../var/www/sites/drupal.predictiveindex.com/backups/travis-db.sql.gz .docker/db/database.sql.gz;
	if [ -f .docker/db/database.sql.gz ]; then gunzip .docker/db/database.sql.gz -f; fi
	docker-compose exec -T php bin/drush @predictiveindex.local sql-drop -yv
	sleep 5
	docker-compose ps
	if command -v pv >/dev/null; then pv .docker/db/database.sql | docker exec -i $(PROJECT_NAME)_mariadb mysql -udrupal -pdrupal drupal; else docker exec -i $(PROJECT_NAME)_mariadb mysql -udrupal -pdrupal drupal < .docker/db/database.sql; fi
	make sanitize-db
	make prep-site
	@echo "Travis environment for $(PROJECT_NAME) is ready."

# https://stackoverflow.com/a/6273809/1826109
%:
	@:
