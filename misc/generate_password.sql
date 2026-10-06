-- Generates a 16-character password from a cryptographically strong source:
-- gen_random_uuid() uses pg_strong_random() (PostgreSQL 13+). Bytes 6 and 8
-- of a UUID carry version/variant bits and are skipped; rejection sampling
-- keeps every character equally likely.

with init(len, chars) as (
  -- edit password length and possible characters here
  select 16, '23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ'
), random_bytes(n, b) as (
  select row_number() over (), get_byte(uuid_send(gen_random_uuid()), i)
  from generate_series(1, 8) uuids, generate_series(0, 15) i
  where i not in (6, 8)
), accepted(n, c) as (
  select n, substr(chars, b % length(chars) + 1, 1)
  from init, random_bytes
  where b < 4 * length(chars)
)
select string_agg(c, '' order by n) as password
from (select c, n from accepted order by n limit (select len from init)) _
;
