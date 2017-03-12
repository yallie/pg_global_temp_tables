# Oracle-style global temporary tables for PostgreSQL

PostgreSQL notion of temporary tables is substantially different from that of Oracle.

* Oracle temporary tables are persistent, so their structure is static and visible to all users, and the content is temporary.
* PostgreSQL temporary tables are dropped either at the end of a session or at the end of a transaction. In PostgreSQL, the structure and the content of a temp table is local for a database backend (a process) which created the table.
* Oracle temporary tables are always defined within a user-specified schema.
* PostgreSQL temporary tables cannot be defined within user's schema, they always use a special temp table schema instead.

Porting large Oracle application relying on many temporary tables can be cumbersome:

* Oracle queries may use `schema.table` notation for temporary tables, which is not allowed in Postgres. We can omit `schema` if it's the same as the current user, but we are still likely to have queries that reference other schemata.
* Postgres requires that each temporary table is created within the same session or transaction before it is accessed.

It gets worse if the application is supposed to work with both Postgres and Oracle, so we can't just fix the queries and litter the code with lots of `create temporary table` statement.

# Enter pg_global_temp_tables

TODO: describe the API and its usage

# How does it work

This library combines a few ideas to emulate Oracle-style temporary tables. First, let's define a view and use it instead of a temporary table. A view is a static object and it's defined within a schema, so it supports the `schema.table` notation used in our Oracle queries. A view can have `instead of` triggers which can create temporary table as needed. There are two problems, however:

* A view on a temporary table is automatically created as temporary, even if we omit the `temporary` keyword. Hence, the restrictions of temporary tables still apply, and we can use schema-qualified names.
* There are no triggers on `select`, so we can't `select` from a view if the temporary table is not yet created.

Ok, we can't just create a view on a temporary table, so let's explore another option: we can define a function returning a table. A function is not temporary, it's defined within a schema, it can create the temporary table as needed and select and return rows from it. The function would look like this (note the `returns table` part of the definition):

```sql
-- let's do our experiments in a separate schema
create schema if not exists stage;

create or replace function stage.select_temp_idname() returns table(id bigint, name varchar) as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	return query select * from test_temp_idname;
end;
$$ language plpgsql;
```

This approach indeed works. We can select from a function, we can access it via schema-qualified name, and we don't have to create a temporary table before accessing it:

```sql
>select * from stage.select_temp_idname()
--
-- id | name
-- ---+-----
```

Still, it's not quite usable:

* We have to add parentheses() after the function name, so we can't just leave Oracle queries as is, and
* Rows returned by a function are read-only.

To finally fix this, we combine both approaches, a view and a function. The view selects rows from the function, and we can make it updatable by means of the `instead of` triggers.

# The complete sample code of a permanent temp table

Here is a working sample:

```sql
create or replace function stage.select_temp_idname() returns table(id bigint, name varchar) as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	return query select * from test_temp_idname;
end;
$$ language plpgsql;

create or replace view stage.temp_idname as 
	select * from stage.select_temp_idname();

create or replace function stage.temp_idname_insert() returns trigger as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	insert into test_temp_idname(id, name) values (new.id, new.name);
	return new;
end;
$$ language plpgsql;

drop trigger if exists temp_idname_insert on stage.temp_idname;
create trigger temp_idname_insert 
	instead of insert on stage.temp_idname
	for each row
	execute procedure stage.temp_idname_insert();
```

Finally, we can use the table just like Oracle:

```sql
>select * from stage.temp_idname
--
-- NOTICE: 42P07: relation "test_temp_idname" already exists, skipping
-- id | name
-- ---+-----

>insert into stage.temp_idname(id, name) values (1, 'one'), (2, 'two')
--
-- NOTICE: 42P07: relation "test_temp_idname" already exists, skipping
-- (2 rows affected)

>select * from stage.temp_idname
--
-- NOTICE: 42P07: relation "test_temp_idname" already exists, skipping
-- id | name
-- ---+-----
-- 1  | one
-- 2  | two
```

One minor thing that annoys me is that pesky notice: relation already exists, skipping. We get the notice every time we access the emulated temporary table via `select` or `insert` statements. Notices can be suppressed using the `client_min_messages` setting:

```sql
set client_min_messages = error
```

But that affects all notices, even meaningful ones. Luckily, Postgres allows specifying settings per function, so that when we enter a function, Postgres applies these settings reverting them back on exit. This way we suppress our notices without affecting the client's session-level setting:

```sql
create or replace function stage.select_temp_idname() returns table(id bigint, name varchar) as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	return query select * from test_temp_idname;
end;
$$ language plpgsql set client_min_messages = error;
```

# Creating permanent temporary tables

Let's recap what's needed to create a permanent temporary table residing in a schema:

1. A function returning the contents of a temporary table
2. A view on the function
3. Instead of insert/update/delete trigger on the view
4. Trigger function that does the job of updating the table

To delete the temporary table, we just drop the (1) and (4) functions with cascade options, and the rest is cleaned up automatically.

It's a bit cumbersome to create these each time we need a temporary table, so let's create a function that does the job. Here, we have a new challenge: specifying the table structure can be quite tricky. Suppose we have a function like this:

```sql
select create_permanent_temp_table(
	p_schema => 'stage', 
	p_table_name => 'complex_temp_table', 
	p_table_structure => '
		id bigint,
		name character varying (256),
		date timestamp(0) with time zone
	',
	p_table_pk => ...
	p_table_pk_columns => ...
	p_table_indexes => ...
	etc.
);
```

The function have to parse table structure, list of primary key columns, indexes, etc. If the function doesn't validate the provided code, it's vulnerable to SQL injection, but validating the code turns out to require a full-blown SQL parser (for example, columns can have default values specified by arbitrary expressions). Worse, the table specification can change in the future, the syntax will evolve over time, etc. I'd like to avoid that kind of complexity in my utility code, so what's the alternative?

The alternative that comes to my mind is to convert an ordinal temporary table into permanent table. We start with creating a temporary table using native PostgreSQL syntax, then we inspect the structure of the table and recreate it as a permanent object:

```sql
-- create a table as usual
create temporary table if not exists complex_temp_table
(
    id bigint,
    name character varying (256),
    date timestamp(0) with time zone,
    constraint complex_temp_table_pk primary key(id)
    -- or just: primary key (id)
)
on commit drop;

-- convert temp table into permanent one
select create_permanent_temp_table(p_schema => 'stage', p_table_name => 'complex_temp_table');
```

# Reverse engineering a temporary table

Inspecting the table structure to generate the `create table` statement usually involves a few queries to the `information_schema` views:

1. Table properties — `information_schema.tables`
2. Column names and types — `information_schema.columns`
3. Primary key — `information_schema.constraint_table_usage`, `constraint_column_usage`, `key_column_usage`.
 
Here's how to list the columns of the 'complex_temp_table' table:

```sql
select c.column_name, c.data_type, c.character_maximum_length,
	c.numeric_precision, c.datetime_precision 
from information_schema.tables t
join information_schema.columns c on c.table_name = t.table_name and c.table_schema = t.table_schema
where t.table_name = 'complex_temp_table'
order by c.ordinal_position

-- column_name | data_type   | char_max_length | num_precision | date_precision
-- ------------+-------------+-----------------+---------------+----------------
-- id          | bigint      | null            | 64            | null
-- name        | varchar     | 256             | null          | null
-- date        | timestamptz | null            | null          | 0
```

Also, there are lots Postgres-specific tables, views and functions in pg_catalog chema, such as format_type function (these are non-standard, however). Querying these tables often works faster than the standard information_schema views because the views combine multiple data sources. As we don't really need to be ANSI SQL standard-compliant, let's use native Postgres tables. Here is how we generate a `create table` statement:

```sql
select format(
	E'create temporary table %I\n(\n%s\n);\n',
	c.relname,
	string_agg(
		format(E'\t%I %s %s',
			a.attname,
			pg_catalog.format_type(a.atttypid, a.atttypmod),
			case when a.attnotnull then 'not null' else '' end
		), E',\n'
		order by a.attnum
	)) as sql
from pg_catalog.pg_class c
	join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
	join pg_catalog.pg_type t on a.atttypid = t.oid
where c.relname = 'complex_temp_table' and c.relpersistence = 't'
group by c.relname

-- create temporary table complex_temp_table
-- (
--     id bigint not null,
--     name character varying(256) null,
--     date timestamp(0) with time zone null
-- );
```

The next challenge is the primary key clause. Note that keys can be compound (i.e. consisting of several columns). Primary keys are listed in `pg_constraint` table as constraints of type 'p', and `conkey` array contains table attributes making the key. Here is a query returning the primary keys and their columns of all temporary tables:

```sql
select c.relname table_name, cc.conname primary_key_name, a.attname column_name
from pg_catalog.pg_constraint cc
	join pg_catalog.pg_class c on c.oid = cc.conrelid
	join pg_catalog.pg_attribute a on a.attrelid = cc.conrelid and a.attnum = any(cc.conkey)
where cc.contype = 'p' and c.relpersistence = 't'
order by cc.conrelid, a.attname

-- table_name         | primary_key_name      | column_name
-- -------------------+-----------------------+------------ 
-- complex_temp_table | complex_temp_table_pk | id
```

>Points of interest: `pg_attribute` join condition includes `any` clause which means that we look for `attnum` values listed in the `conkey` array: `a.attnum = any(cc.conkey)`.

Finally, let's combine the two queries to get the table definition including the primary key. To make sure it handles the compound keys, let's create another temporary table with more than one primary key column:

```sql
-- sample table
create temporary table if not exists another_temp_table
(
    first_name varchar,
    last_name varchar,
    date timestamp(0) with time zone,
    primary key(first_name, last_name)
)
on commit drop;

-- the combined query
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

-- create temporary table another_temp_table
-- (
--     first_name character varying not null,
--     last_name character varying not null,
--     date timestamp(0) with time zone,
--     constraint another_temp_table_pkey primary key(first_name, last_name)
-- );
```

>Points of interest: `string_agg` function takes the `order by` clause to preserve the order or primary key columns and the order of table columns (these two don't always use the same order).

The query also handles tables with no defined primary key (try yourself creating different temporary tables and see how it works).

# Instead of insert/update/delete trigger

Simple views in PostgreSQL are usually updatable by default (a view is automatically updatable if it doesn't have [joins, group by and unions](https://www.postgresql.org/docs/current/static/sql-createview.html)). But the view we created is not simple: it gets its data from a function, not from a table, so it requires the instead of triggers. All three triggers can be implemented using a single function that looks like this:

```sql
create or replace function temp_tag_idlist_iud() returns trigger as $$
begin
	-- temporary table definition (skipped)
	create temporary table if not exists temp_id_name_table ...;

	if tg_op = 'INSERT' then
		insert into temp_id_name_table(id, name) 
		values (new.id, new.name);
		return new;
	elsif tg_op = 'UPDATE' then
		update temp_id_name_table 
		set id = new.id, name = new.name
		where id = old.id;
		return new;
	elsif tg_op = 'DELETE' then
		delete from temp_id_name_table 
		where id = old.id;
		return old;
	end if;
end;
$$ language plpgsql set client_min_messages to error;
```

Trigger function uses the built-in `tg_op` variable to distinguish between different operations handled by the trigger. To generate the important part of the trigger we need to prepare
several lists of columns like the following:

* id, name (comma-separated list of all columns)
* new.id, new.name (comma-separated list of all columns, prepended with `new`)
* id = new.id, name = new.name (list of `x = new.x` expressions for all columns)
* id = old.id (list of `x = old.x` expressions, primary key columns only)
* id bigint, name varchar (list of all columns and their types).

We can use either `information_schema.columns` view or `pg_attributes` table to prepare these lists of columns:

```sql
-- generate the lists of columns
select
	string_agg(a.attname, ', ') as all_columns,
	string_agg(format('new.%I', a.attname), ', ') as new_columns,
	string_agg(format('%I = new.%I', a.attname, a.attname), ', ') as assignments,
	string_agg(format('%I %s', a.attname, 
		pg_catalog.format_type(a.atttypid, a.atttypmod)), ', ') as column_types
from pg_catalog.pg_class c
	join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
where c.relname = 'another_temp_table' and c.relpersistence = 't';

-- generate the list of primary key columns
select string_agg(format('%I = old.%I', a.attname, a.attname), ' and ' 
	order by array_position(cc.conkey, a.attnum)) as old_columns
from pg_catalog.pg_constraint cc
	join pg_catalog.pg_class c on c.oid = cc.conrelid
	join pg_catalog.pg_attribute a on a.attrelid = cc.conrelid and a.attnum = any(cc.conkey)
where cc.contype = 'p' and c.relname = 'another_temp_table' and c.relpersistence = 't'
group by cc.conrelid, cc.conname;
```

# Assembling the pieces together

The rest of the job is straighforward:
* check if the given temporary table exists
* rename the existing temporary table to avoid the conflict with the view
* generate temporary table definition as returned by the query above
* generate the trigger function with insert, update and delete statements
* format the boilerplate code using the table name and other generated parts
* execute the generated code.

The view we're creating will have the same name as the source temporary table. So, to avoid the name conflict we'll rename the original temporary table by adding a suffix.

```sql
create or replace function create_permanent_temp_table(p_table_name varchar, p_schema varchar) returns void as $$
declare
	v_table_name varchar := p_table_name || '$tmp';
	v_trigger_name varchar := p_table_name || '$iud';
	v_final_statement text;
	v_table_statement text; -- create temporary table...
	v_all_column_list text; -- id, name, ...
	v_new_column_list text; -- new.id, new.name, ...
	v_assignment_list text; -- id = new.id, name = new.name, ...
	v_cols_types_list text; -- id bigint, name varchar, ...
	v_old_column_list text; -- id = old.id
begin
	-- check if the temporary table exists
	if not exists(select 1 from pg_class where relname = p_table_name and relpersistence = 't') then
		raise exception 'Temporary table % does not exist.', p_table_name;
	end if;
	
	-- generate the temporary table statement (skipped, see above)
	with pkey as ...
	select format...
	into v_table_statement...;

	-- generate the lists of columns (skipped, see above)
	select ...
	into v_all_column_list, v_new_column_list, v_assignment_list...;

	-- generate the list of primary key columns (skipped, see above)
	select ...
	into v_old_column_list...;

	-- generate the view function
	v_final_statement := format(E'-- rename the original table to avoid the conflict
alter table %I rename to %I;

-- the function to select from the temporary table 
create or replace function %I.%I() returns table(%s) as $x$
begin
	-- create table statement
%s

	return query select * from %I;
end;
$x$ language plpgsql 
set client_min_messages to error;\n',
	p_table_name, v_table_name,
	p_schema, p_table_name, v_cols_types_list,
	v_table_statement, v_table_name);

	-- generate the view
	v_final_statement := v_final_statement || format(E'
create or replace view %I.%I as 
	select * from %I.%I();\n',
	p_schema, p_table_name, p_schema, p_table_name);

	-- generate the trigger function
	v_final_statement := v_final_statement || format(E'
create or replace function %I.%I() returns trigger as $x$
begin
	-- create temporary table
%s

	-- handle the trigger operation
	if lower(tg_op) = \'insert\' then
		insert into %I(%s) 
		values (%s);
		return new;
	elsif lower(tg_op) = \'update\' then
		update %I 
		set %s
		where %s;
		return new;
	elsif lower(tg_op) = \'delete\' then
		delete from %I 
		where %s;
		return old;
	end if;
end;
$x$ language plpgsql set client_min_messages to error;\n',
	p_schema, v_trigger_name, v_table_statement, -- function header
	v_table_name, v_all_column_list, v_new_column_list, -- insert
	v_table_name, v_assignment_list, v_old_column_list, -- update
	v_table_name, v_old_column_list); -- delete

	-- generate the view trigger
	v_final_statement := v_final_statement || format(E'
drop trigger if exists %I on %I.%I;
create trigger %I 
	instead of insert or update or delete on %I.%I
	for each row
	execute procedure %I.%I();',
	v_trigger_name, p_schema, p_table_name,
	v_trigger_name, p_schema, p_table_name,
	p_schema, v_trigger_name);

	-- execute the statement
	execute v_final_statement;
end;
$$ language plpgsql;
```

To be continued :)
