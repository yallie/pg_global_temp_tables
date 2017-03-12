-- create ordinal temporary table
create temporary table if not exists test_temp_idname
(
	id numeric(10), 
	name varchar(123), 
	constraint test_pk primary key(id, name)
) on commit drop;

-- check if the table exists
select * from information_schema.tables 
where table_name = 'test_temp_idname' and 
	table_type = 'LOCAL TEMPORARY' and
	table_catalog = current_catalog;

-- get table columns
select column_name, data_type, numeric_precision, character_octet_length, is_nullable, * 
from information_schema.columns c
join information_schema.tables t on t.table_name = c.table_name and t.table_catalog = c.table_catalog
where t.table_name = 'test_temp_idname' and 
	t.table_type = 'LOCAL TEMPORARY' and
	t.table_catalog = current_catalog
order by ordinal_position

-- get the constraints
select * from information_schema.constraint_table_usage
where table_name = 'test_temp_idname'

select * from information_schema.constraint_column_usage
where table_name = 'test_temp_idname'

-- generate the create table statement
with pkey as
(
	select cc.conrelid, format(E',
	constraint %I primary key(%s)', cc.conname,
		string_agg(a.attname, ', ' order by array_position(cc.conkey, a.attnum))) pkey
	from pg_catalog.pg_constraint cc
		join pg_catalog.pg_class c on c.oid = cc.conrelid
		join pg_catalog.pg_attribute a on a.attrelid = cc.conrelid and a.attnum = any(cc.conkey)
	where cc.contype = 'p'
	group by cc.conrelid, cc.conname
)
select format(E'create temporary table %I\n(\n%s%s\n);\n',
	c.relname,
	string_agg(
		format(E'\t%I %s%s',
			a.attname,
			pg_catalog.format_type(a.atttypid, a.atttypmod),
			case when a.attnotnull then ' not null' else '' end
		), E',\n'
		order by a.attnum
	),
	(select pkey from pkey where pkey.conrelid = c.oid)) as sql
from pg_catalog.pg_class c
	join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
	join pg_catalog.pg_type t on a.atttypid = t.oid
where c.relname = 'another_temp_table' and c.relpersistence = 't'
group by c.oid, c.relname;
