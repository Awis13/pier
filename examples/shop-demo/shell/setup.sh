#!/bin/sh
# The shell service: tools, the `status` command, then waiting for you.
apk add --no-cache bash postgresql-client redis curl ncurses >/dev/null 2>&1
install -m 0755 /opt/shell/status /usr/local/bin/status
# Terminals opened later get the service's connection settings too.
env | grep -E '^(PG|REDIS_)' | sed 's/^/export /' > /etc/profile.d/shop-env.sh
cat > /etc/profile.d/pier.sh <<'PROFILE'
export PS1='\[\e[1;36m\]shop\[\e[0m\]:\w\$ '
printf '\n  \033[1mshop-demo shell\033[0m: type \033[1;36mstatus\033[0m (or status -w to watch).\n  psql and redis-cli are set up: try  psql -c "select count(*) from orders"\n\n'
PROFILE
echo "shell: ready, open a terminal and type status"
exec sleep infinity
