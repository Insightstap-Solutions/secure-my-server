#!/usr/bin/env bats

setup() { load helpers; }
run_ds() { run bash "$SCRIPTS/detect_stack.sh" --root "$ROOT" "$@"; }

@test "aapanel: panel, two nginx binaries, PHP short list, public MySQL without firewall" {
  setup_sandbox aapanel ss
  run_ds
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^INFO\tstack.os\tCentOS Linux 7')" ]
  [ -n "$(line_matching $'^INFO\tstack.panel\taaPanel \\(/www/server/panel\\)')" ]
  [ -n "$(line_matching $'^WARN\tstack.webserver\t2 nginx binaries: /usr/sbin/nginx /www/server/nginx/sbin/nginx')" ]
  [ -n "$(line_matching $'^INFO\tstack.php\t/www/server/php/84/sbin/php-fpm 8.4.26 fpm-fcgi')" ]
  [ -n "$(line_matching $'^INFO\tstack.web_owner\tports 80/443 owned by: :80=nginx@0.0.0.0, :443=nginx@0.0.0.0')" ]
  [ -n "$(line_matching $'^CRIT\tstack.public_port\t0.0.0.0:3306 \\(mysqld\\) MySQL .*no host firewall.*nc -vz')" ]
  # php-fpm on 127.0.0.1:9000 is fine
  ! grep -q $'stack.public_port\t127.0.0.1:9000' <<<"$output"
  [ -n "$(line_matching $'^WARN\tstack.firewall\tno active host firewall')" ]
}

@test "docker host: ufw is on but Docker-published MySQL bypasses it (CRIT), DOCKER-USER empty (WARN)" {
  setup_sandbox dockerhost ss iptables docker
  run_ds --docker
  [ -n "$(line_matching $'^INFO\tstack.firewall\tufw enabled')" ]
  [ -n "$(line_matching $'^WARN\tstack.firewall\tiptables DOCKER-USER chain is empty')" ]
  [ -n "$(line_matching $'^CRIT\tstack.public_port\t0.0.0.0:3306 \\(docker-proxy\\) MySQL .*published by Docker')" ]
  [ -n "$(line_matching $'^CRIT\tstack.public_port\tcontainer shop-mysql publishes MySQL port 3306')" ]
  [ -n "$(line_matching $'^INFO\tstack.docker\tdocker running: 4 container\\(s\\); compose projects: shop$')" ]
  [ -n "$(line_matching $'^INFO\tstack.container\tshop-app image=php:8.3-fpm-alpine project=shop')" ]
  # redis on loopback is not a finding
  ! grep -q '6379' <<<"$(grep public_port <<<"$output")"
}

@test "docker host with filtering DOCKER-USER rules downgrades to WARN" {
  setup_sandbox dockerhost ss iptables docker
  export SMS_FAKE="$BATS_TEST_TMPDIR/fake"; "$CP" -r "$FIXTURES/dockerhost/fake" "$SMS_FAKE"
  printf -- '-N DOCKER-USER\n-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 3306 -j DROP\n-A DOCKER-USER -j RETURN\n' >"$SMS_FAKE/iptables-DOCKER-USER"
  run_ds --docker
  [ -n "$(line_matching $'^WARN\tstack.public_port\t0.0.0.0:3306 \\(docker-proxy\\)')" ]
  ! grep -q $'^CRIT\tstack.public_port' <<<"$output"
}

@test "no ss and no netstat is a SKIP, not a failure" {
  setup_sandbox aapanel
  run_ds
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^SKIP\tstack.listen\tneither ss nor netstat')" ]
}
