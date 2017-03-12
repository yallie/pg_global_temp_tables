create or replace function create_permanent_temp_table(p_schema varchar, p_table_name varchar) returns void as $$
declare
	v_table_statement text;
begin
	-- check if the temporary table exists
	if not exists(select 1 from pg_class where relname = p_table_name and relpersistence = 't') then
		raise exception 'Temporary table % does not exist.', p_table_name;
	end if;
	
	-- generate the temporary table statement
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
	select format(E'\tcreate temporary table if not exists %I\n(\n%s%s\n)\n\ton commit drop;',
		c.relname,
		string_agg(
			format(E'\t\t%I %s%s',
				a.attname,
				pg_catalog.format_type(a.atttypid, a.atttypmod),
				case when a.attnotnull then ' not null' else '' end
			), E',\n'
			order by a.attnum
		),
		(select pkey from pkey where pkey.conrelid = c.oid)) as sql
	into v_table_statement
	from pg_catalog.pg_class c
		join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
		join pg_catalog.pg_type t on a.atttypid = t.oid
	where c.relname = p_table_name and c.relpersistence = 't'
	group by c.oid, c.relname;
end;
$$ language plpgsql;
