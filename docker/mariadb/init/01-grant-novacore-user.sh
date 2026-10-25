# Sourced by the MariaDB entrypoint the first time the data volume is created.
# Give the shared dev user access to every database, so `novacore db create`
# doesn't need to manage per-site users.
docker_process_sql <<-EOSQL
	GRANT ALL PRIVILEGES ON *.* TO '${MARIADB_USER}'@'%' WITH GRANT OPTION;
	FLUSH PRIVILEGES;
EOSQL
