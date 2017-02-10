# Oracle-style global temporary tables for PostgreSQL

PostgreSQL notion of temporary tables is substantially different from that of Oracle.

* Oracle temporary tables are persistent, so their structure is static and visible to all users, and the content is temporary.
* PostgreSQL temporary tables are dropped either at the end of a session or at the end of a transaction. In PostgreSQL, the structure and the content of a temp table is local for a database backend (a process) which created the table.
* Oracle temporary tables are always defined within a user-specified schema.
* PostgreSQL temporary tables cannot be defined within user's schema, they always use a special temp table schema instead.

Porting large Oracle application relying on many temporary tables can be cumbersome:

* Oracle queries may use `SCHEMA.TABLE` notion for temporary tables, which is not allowed in Postgres. We can omit `SCHEMA` if it's the same as the current user, but we probably have queries that reference other `SCHEMA`ta.
* Postgres requires that each temporary table is created within the same session or transaction before it is accessed.

It gets worse if the application is supposed to work with both Postgres and Oracle, so we can't just fix the queries and litter the code with lots of `CREATE TEMPORARY TABLE` statement.

# Enter pg_global_temp_tables

This library combines a few ideas to emulate Oracle-style temporary tables. First, let's define a view and use it instead of a temporary table. A view is a static object and it's defined within a schema, so it supports the `SCHEMA.TABLE` notion used in our Oracle queries. A view can have `INSTEAD OF` triggers which can create temporary table as needed. There are two problems, however:

* A view on a temporary table is automatically created as temporary, even if we omit the `TEMPORARY` keyword. Hence, the restrictions of temporary tables still apply, and we can use schema-qualified names.
* There are no triggers on `SELECT`, so we can't `SELECT` from a view if the temporary table is not yet created.

Ok, we can't just create a `VIEW` on a temporary table, so let's explore another option: we can define a function returning a table. A function is not temporary, it's defined within a schema, it can create the temporary table as needed and select and return rows from it. The function would look like this:

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

To finally fix this, we combine both approaches, a view and a function. The view selects rows from the function, and we can make it updateable by means of the `INSTEAD OF` triggers.

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
$$ language plpgsql set search_path to stage;

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

One minor thing that annoys me is that pesky notice: relation already exists, skipping. We get the notice every time we access the emulated temporary table via `SELECT` or `INSERT` statements. Notices can be suppressed using the `client_min_messages` setting:

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

To be continued :)
