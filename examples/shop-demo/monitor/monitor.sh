#!/bin/sh
# A live dashboard on :8080, drawn again every 2 s from Postgres and Redis.
apk add --no-cache postgresql-client redis busybox-extras >/dev/null 2>&1
mkdir -p /www
echo '<meta http-equiv="refresh" content="1"><body style="background:#0b0e14;color:#ccc;font:16px sans-serif">Starting...</body>' > /www/index.html
busybox-extras httpd -f -p 8080 -h /www &
echo "monitor: dashboard on :8080"
R="redis-cli -h ${REDIS_HOST:-cache}"
prev_tx=0
while true; do
  q() { psql -qtAX -F '|' -c "$1" 2>/dev/null; }
  orders=$(q "select count(*) from orders")
  last_min=$(q "select count(*) || '|' || coalesce(sum(total),0) from orders where created > now() - interval '1 minute'")
  today=$(q "select coalesce(sum(total),0)::numeric(12,2) from orders where created > date_trunc('day', now())")
  dbsize=$(q "select pg_size_pretty(pg_database_size('shop'))")
  conns=$(q "select count(*) from pg_stat_activity where datname = 'shop'")
  hit=$(q "select round(100.0 * sum(blks_hit) / greatest(sum(blks_hit) + sum(blks_read), 1), 1) from pg_stat_database where datname = 'shop'")
  tx=$(q "select xact_commit from pg_stat_database where datname = 'shop'")
  tps=$(( (${tx:-0} - prev_tx) / 2 )); [ "$prev_tx" -eq 0 ] && tps=0; prev_tx=${tx:-0}
  bars=$(q "select string_agg(n::text, ' ' order by m) from (
              select m, (select count(*) from orders where created >= m and created < m + interval '1 minute') n
              from generate_series(date_trunc('minute', now()) - interval '29 minutes', date_trunc('minute', now()), interval '1 minute') m) s")
  top=$(q "select p.name || '|' || sum(o.qty) || '|' || sum(o.total)::numeric(12,2) from orders o join products p on p.id = o.product_id
           group by p.name order by sum(o.total) desc limit 6")
  rinfo=$($R info 2>/dev/null | tr -d '\r')
  rget() { echo "$rinfo" | sed -n "s/^$1://p"; }
  rmem=$(rget used_memory_human); rops=$(rget instantaneous_ops_per_sec); rcli=$(rget connected_clients)
  rup=$(rget uptime_in_seconds); rkeys=$($R dbsize 2>/dev/null)
  live=$($R get orders:total 2>/dev/null)
  feed=$($R lrange feed 0 11 2>/dev/null)

  lm_n=${last_min%%|*}; lm_sum=${last_min#*|}
  max=1; for b in $bars; do [ "$b" -gt "$max" ] && max=$b; done
  {
    cat <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="2"><title>Shop Monitor</title><style>
:root{--bg:#0b0e14;--card:#131824;--line:#222a3a;--fg:#e6e9ef;--dim:#8a93a6;--acc:#5eead4;--acc2:#a78bfa;--warn:#fbbf24}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,system-ui,sans-serif;padding:20px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--dim);margin-bottom:18px}.live{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--acc);margin-right:6px;animation:p 1s infinite}
@keyframes p{50%{opacity:.3}}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}.k{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.v{font-size:28px;font-weight:700;margin-top:4px;font-variant-numeric:tabular-nums}.v small{font-size:14px;color:var(--dim);font-weight:500}
.row{display:grid;grid-template-columns:2fr 1fr;gap:12px}@media(max-width:800px){.row{grid-template-columns:1fr}}
.bars{display:flex;align-items:flex-end;gap:3px;height:120px;margin-top:10px}.bars div{flex:1;background:linear-gradient(var(--acc),var(--acc2));border-radius:3px 3px 0 0;min-height:2px}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}td{padding:6px 4px;border-top:1px solid var(--line)}td.r{text-align:right}td.d{color:var(--dim)}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:13px}
</style></head><body>
<h1><span class="live"></span>Shop Monitor</h1><div class="sub">Postgres <b>db</b> and Redis <b>cache</b> inside Pier, redrawn every 2 s at $(date +%H:%M:%S)</div>
<div class="grid">
<div class="card"><div class="k">Orders</div><div class="v">${orders:-0}</div></div>
<div class="card"><div class="k">Last minute</div><div class="v">${lm_n:-0} <small>\$${lm_sum:-0}</small></div></div>
<div class="card"><div class="k">Revenue today</div><div class="v">\$${today:-0}</div></div>
<div class="card"><div class="k">Postgres</div><div class="v">${tps} <small>tx/s</small></div><div class="d mono">${dbsize:-?}, ${conns:-?} conns, ${hit:-?}% cache hits</div></div>
<div class="card"><div class="k">Redis</div><div class="v">${rops:-0} <small>ops/s</small></div><div class="d mono">${rmem:-?}, ${rkeys:-?} keys, ${rcli:-?} clients, up ${rup:-0}s</div></div>
<div class="card"><div class="k">Counted in Redis</div><div class="v">${live:-0}</div><div class="d mono">orders since the shop opened</div></div>
</div>
<div class="row"><div class="card"><div class="k">Orders per minute, last 30 minutes</div><div class="bars">
HTML
    for b in $bars; do printf '<div style="height:%d%%" title="%s"></div>' $((b * 100 / max)) "$b"; done
    echo '</div></div><div class="card"><div class="k">Top products</div><table>'
    echo "$top" | while IFS='|' read -r name qty sum; do
      [ -n "$name" ] && printf '<tr><td>%s</td><td class="r d">%s</td><td class="r">$%s</td></tr>' "$name" "$qty" "$sum"
    done
    echo '</table></div></div><div class="card" style="margin-top:12px"><div class="k">Live orders (from Redis)</div><table class="mono">'
    echo "$feed" | while IFS='|' read -r t id who what sum; do
      [ -n "$t" ] && printf '<tr><td class="d">%s</td><td>%s</td><td>%s</td><td>%s</td><td class="r">$%s</td></tr>' "$t" "$id" "$who" "$what" "$sum"
    done
    echo '</table></div></body></html>'
  } > /www/index.tmp && mv /www/index.tmp /www/index.html
  sleep 2
done
