-- create the function that generates the check digit ...
CREATE OR REPLACE FUNCTION pg_temp.rec2check(rec_num INTEGER) RETURNS CHAR as $$
DECLARE
	a TEXT[];
	counter INTEGER;
	agg_sum INTEGER;
BEGIN
	SELECT regexp_split_to_array($1::VARCHAR, '') INTO a;
	-- counter is what we're multiplying by
	counter := 2;
	agg_sum := 0;
	FOR i IN REVERSE array_length(a, 1)..1 LOOP
		agg_sum := agg_sum + (a[i]::INTEGER * counter);
		counter := counter + 1;
	END LOOP;

	IF (agg_sum % 11) = 10 THEN
		RETURN 'x';
	ELSE
		RETURN agg_sum % 11;
	END IF;

END;
$$ LANGUAGE plpgsql
;


-- This seems silly, but we have to do a little bit of prep work, since there's no index on
-- the `blanket_purchase_order_num` column, and we'll be leaning on that heavily in the
-- upcoming queries
DROP TABLE IF EXISTS temp_order_record
;


CREATE TEMPORARY TABLE temp_order_record AS
SELECT
o.record_id,
o.vendor_record_code,
o.order_date_gmt,
o.form_code,
o.order_status_code,
o.blanket_purchase_order_num,
o.estimated_price::numeric(30,2) as estimated_price

FROM
sierra_view.order_record as o
;


CREATE INDEX temp_blanket_purchase_order_num on temp_order_record (blanket_purchase_order_num)
;


DROP TABLE IF EXISTS temp_blanket_purchase_order_metadata
;


CREATE TEMP TABLE temp_blanket_purchase_order_metadata AS
WITH temp_blanket_purchase_order_num AS (
 	SELECT
 	DISTINCT
 	blanket_purchase_order_num
	FROM
	temp_order_record
)

SELECT
t.blanket_purchase_order_num,
(
	SELECT
	MAX(o.order_date_gmt)
	FROM
	temp_order_record as o
	WHERE
	o.blanket_purchase_order_num = t.blanket_purchase_order_num
) as latest_order_date,
(
	SELECT
	MAX(r.record_last_updated_gmt)
	FROM
	temp_order_record as o
	JOIN
	sierra_view.record_metadata as r
	ON
	  r.id = o.record_id
	
	WHERE
	o.blanket_purchase_order_num = t.blanket_purchase_order_num
) as last_order_record_updated

FROM
temp_blanket_purchase_order_num as t
;



-- Target the purchase orders we wish to produce
-- gather the list of POs we're targetting
DROP TABLE IF EXISTS temp_target_purchase_orders
;

CREATE TEMP TABLE temp_target_purchase_orders AS 
SELECT
*
FROM
temp_blanket_purchase_order_metadata as t

WHERE
-- this is where we will substitue our target timestampe at
-- TODO: template this
t.last_order_record_updated::TIMESTAMP > '2020-02-10'::TIMESTAMP

ORDER BY
last_order_record_updated DESC
;


-- SELECT * FROM temp_target_purchase_orders
-- ;


-- build our list of order record info from the target list of purchase orders built previously ...
DROP TABLE IF EXISTS temp_order_record_info
;


CREATE TEMP TABLE temp_order_record_info AS
SELECT
o.record_id as order_record_id,
l.bib_record_id as bib_record_id,
(
	SELECT
-- 	r.record_type_code || r.record_num || 'a'
	r.record_type_code || r.record_num || pg_temp.rec2check(r.record_num)
	FROM
	sierra_view.record_metadata as r
	WHERE
	r.id = o.record_id
	LIMIT 1	
) as order_record_num,
o.vendor_record_code,
(
	SELECT
	rb.record_type_code || r.record_num || 'a'
	FROM
	sierra_view.record_metadata as rb
	WHERE
	rb.id = l.bib_record_id
	LIMIT 1	
) as bib_record_num,
(
	SELECT
	(
		-- performing subquery so that we can return one result for our extracted isbn
		SELECT
		regexp_matches(
			--regexp_replace(trim(v.field_content), '(\|[a-z]{1})', '', 'ig'), -- get the call number strip the subfield indicators
			v.field_content,
			'[0-9]{9,10}[x]{0,1}|[0-9]{12,13}[x]{0,1}', -- the regex to match on (10 or 13 digits, with the possibility of the 'X' character in the check-digit spot)
			'i' -- regex flags; ignore case
		)
		FROM
		sierra_view.varfield as v1

		WHERE
		v1.record_id = v.record_id

		LIMIT 1
	)[1]::varchar(30) as isbn_extracted
	FROM
	sierra_view.varfield as v

	WHERE
	v.marc_tag || v.varfield_type_code = '020i'
	AND v.record_id = l.bib_record_id
	AND v.field_content !~* '^\|z' -- exclude the ones that are canceled, even if they are first listed

	ORDER BY
	v.occ_num

	LIMIT 1
) as isbn,
p.best_title,
(
	SELECT
	string_agg(v.field_content, ', ' order by v.occ_num)
	FROM
	sierra_view.varfield as v
	WHERE
	v.record_id = o.record_id
	AND v.varfield_type_code = 'v' -- vendor note

) as order_note,
p.best_author,
o.order_date_gmt::date as order_date,
r.record_last_updated_gmt,
o.form_code,
o.order_status_code,
o.blanket_purchase_order_num,
cmf.fund_code,
f.code,
o.estimated_price,
sum(cmf.copies) as copies,
( o.estimated_price * sum(cmf.copies) )::numeric(30,2) as subtotal

FROM
temp_order_record as o

JOIN
sierra_view.record_metadata as r
ON
  r.id = o.record_id
JOIN
sierra_view.order_record_cmf as cmf
ON
  o.record_id = cmf.order_record_id

LEFT OUTER JOIN
sierra_view.fund_master AS f
ON
  NULLIF(
	regexp_replace(cmf.fund_code, '[^0-9]*', '', 'g'),
	''
  )::int = f.code_num

LEFT OUTER JOIN
sierra_view.bib_record_order_record_link as l
ON
  l.order_record_id = o.record_id

LEFT OUTER JOIN
sierra_view.bib_record_property as p
ON
  p.bib_record_id = l.bib_record_id

WHERE
o.blanket_purchase_order_num IN (
	SELECT
	t.blanket_purchase_order_num
	FROM
	temp_target_purchase_orders as t
)
AND cmf.location_code != 'multi'

GROUP BY
o.record_id,
l.bib_record_id,
order_record_num,
o.vendor_record_code,
bib_record_num,
isbn,
p.best_title,
p.best_author,
r.record_last_updated_gmt,
order_date,
o.form_code,
o.order_status_code,
o.blanket_purchase_order_num,
cmf.fund_code,
f.code,
o.estimated_price
;


-- get the vendor record addresses
DROP TABLE IF EXISTS temp_vendor_record_address;
CREATE TEMP TABLE temp_vendor_record_address
AS
SELECT
v.record_id as vendor_record_id,
v.code,
a.display_order,
a.addr1,
a.addr2,
a.addr3,
a.village,
a.city,
a.region,
a.postal_code,
a.country

FROM
sierra_view.vendor_record as v 

JOIN
sierra_view.vendor_record_address as a
ON
  a.vendor_record_id = v.record_id

-- JOIN to the address type to get the code type of the address
JOIN
sierra_view.vendor_record_address_type as t
ON
  t.id = a.vendor_record_address_type_id

WHERE
v.code IN (
	SELECT
	DISTINCT orders.vendor_record_code
	FROM
	temp_order_record_info as orders
)
AND t.code = 'a'
;


DROP TABLE IF EXISTS temp_blanket_purchase_order_num_last_update
;


-- create the temp table for the last update timestamp for the purchase order on a whole
CREATE TEMP TABLE temp_blanket_purchase_order_num_last_update AS
SELECT
t.blanket_purchase_order_num,
MAX(t.record_last_updated_gmt) as last_updated_gmt

FROM
temp_order_record_info as t

GROUP BY
t.blanket_purchase_order_num
;


-- create some indexes to speed things up
CREATE INDEX index_temp_order_record_info_blanket_purchase_order_num ON temp_order_record_info (blanket_purchase_order_num)
;

CREATE INDEX index_temp_vendor_record_address_code ON temp_vendor_record_address (code)
;

CREATE INDEX index_temp_blanket_purchase_order_num_last_update ON temp_blanket_purchase_order_num_last_update (last_updated_gmt)
;


-- 
-- TESTING:
-- take a look at output from temp_blanket_purchase_order_metadata
-- 
-- SELECT
-- *
-- FROM
-- temp_blanket_purchase_order_metadata