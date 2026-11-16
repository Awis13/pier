#!/bin/sh
# Makes orders forever: one every 0.3-2 s, into Postgres and Redis.
apk add --no-cache postgresql-client redis >/dev/null 2>&1
echo "shop: open for business"
R="redis-cli -h ${REDIS_HOST:-cache}"
n=0
while true; do
  row=$(psql -qtAX -F '|' -c "
    with p as (select id, name, price from products order by power(random(), 1.6) * id limit 1),
         c as (select id, handle from customers order by random() limit 1),
         q as (select 1 + floor(power(random(), 3) * 4)::int as qty),
         o as (insert into orders (customer_id, product_id, qty, total)
               select c.id, p.id, q.qty, q.qty * p.price from c, p, q returning id, qty, total)
    select o.id, c.handle, p.name, o.qty, o.total from o, c, p;" 2>&1) || { echo "shop: $row"; sleep 2; continue; }
  id=${row%%|*}; rest=${row#*|}
  handle=${rest%%|*}; rest=${rest#*|}
  product=${rest%%|*}; rest=${rest#*|}
  qty=${rest%%|*}; total=${rest#*|}
  now=$(date +%H:%M:%S)
  $R incr orders:total >/dev/null
  $R incrbyfloat revenue:total "$total" >/dev/null
  $R zincrby top:products "$qty" "$product" >/dev/null
  $R lpush feed "$now|#$id|$handle|$qty x $product|$total" >/dev/null
  $R ltrim feed 0 49 >/dev/null
  $R publish orders "$id" >/dev/null
  n=$((n + 1))
  [ $((n % 25)) -eq 0 ] && echo "shop: $n orders so far, last #$id $handle $qty x $product = $total"
  # 0.3-2 s between orders.
  sleep "$(awk 'BEGIN{srand(); printf "%.1f", 0.3 + rand() * 1.7}')"
done
