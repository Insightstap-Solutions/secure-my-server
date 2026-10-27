# SERVER context (inside each server { } that proxies to PHP). Put it in a file
# your panel does not regenerate, and include it, e.g.
#   distro nginx: include /etc/nginx/snippets/edge-limits.conf;
#   aaPanel:      /www/server/panel/vhost/nginx/proxy/<site>/00-edge-limits.conf
if ($edge_bad_multipart) { return 400; }

client_header_timeout 15s;   # per read, not per request: slow big uploads still work
client_body_timeout   30s;
send_timeout          30s;
client_max_body_size  2m;    # small default; raise only on real upload routes

limit_req  zone=edge_app    burst=100 nodelay;
limit_req  zone=edge_static burst=500 nodelay;
limit_req  zone=edge_hook   burst=300 nodelay;
limit_conn edge_conn_app  60;
limit_conn edge_conn_hook 200;
limit_req_status  429;
limit_conn_status 429;

# Upload routes: raise the body size ONLY where the app really takes uploads,
# and copy the SAME proxy/fastcgi settings as the main location, e.g.
# location ^~ /upload { client_max_body_size 60m; proxy_pass http://127.0.0.1:8080; ... }
#
# Webhook senders (payment providers etc.) must never be throttled into failures:
# give their paths the "hook" class in 0.request_limits.conf.
#
# Test, then reload, with the binary that is really LIVE (see guides/web/nginx.md):
#   nginx -t && nginx -s reload
#   aaPanel: /www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf && \
#            /www/server/nginx/sbin/nginx -s reload -c /www/server/nginx/conf/nginx.conf
