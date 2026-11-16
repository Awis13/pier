-- Fake but plausible data: 400 customers, 24 products, 6000 orders over a week.
create table customers (
    id serial primary key,
    handle text not null,
    joined timestamptz not null default now()
);
create table products (
    id serial primary key,
    name text not null,
    price numeric(8,2) not null
);
create table orders (
    id bigserial primary key,
    customer_id int not null references customers(id),
    product_id int not null references products(id),
    qty int not null,
    total numeric(10,2) not null,
    created timestamptz not null default now()
);
create index on orders (created);

insert into customers (handle, joined)
select (array['neon','pixel','quiet','rusty','lunar','brisk','velvet','cosmic','tiny','wild','amber','frost'])[1 + (i % 12)]
       || '_' ||
       (array['otter','falcon','badger','lynx','heron','panda','koala','gecko','raven','tapir'])[1 + ((i / 12) % 10)]
       || (i % 97),
       now() - (random() * interval '180 days')
from generate_series(1, 400) i;

insert into products (name, price) values
 ('Mechanical keyboard', 129.00), ('USB-C hub', 39.90), ('Noise-cancelling headphones', 249.00),
 ('4K monitor', 399.00), ('Ergonomic mouse', 59.00), ('Laptop stand', 45.00),
 ('Webcam', 79.00), ('Desk lamp', 34.50), ('Coffee beans 1 kg', 24.90),
 ('Cold brew bottle', 18.00), ('Standing desk', 549.00), ('Cable organiser', 12.90),
 ('Mesh router', 189.00), ('SSD 2 TB', 159.00), ('Raspberry Pi 5', 89.00),
 ('Soldering kit', 64.00), ('Notebook, dotted', 9.90), ('Fountain pen', 42.00),
 ('Plant, monstera', 29.00), ('Hoodie', 55.00), ('Sticker pack', 6.50),
 ('Thermal mug', 22.00), ('E-reader', 139.00), ('Drone, small', 299.00);

insert into orders (customer_id, product_id, qty, total, created)
select c, p, q, q * (select price from products where id = p), t
from (
    select 1 + floor(random() * 400)::int as c,
           1 + floor(power(random(), 1.6) * 24)::int as p,
           1 + floor(power(random(), 3) * 4)::int as q,
           now() - (random() * interval '7 days') as t
    from generate_series(1, 6000)
) s;
