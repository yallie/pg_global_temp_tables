-- 1. Define a function returning the contents of a temporary table
-- 2. Define a view on the function
-- 3. Define instead of triggers on the view

-- Table structure is like this:
-- create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;

-- Use a separate schema for the experiments
create schema if not exists stage;

create or replace function stage.select_temp_idname() returns table(id bigint, name varchar) as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	return query select * from test_temp_idname;
end;
$$ language plpgsql set client_min_messages = error;

create or replace view stage.temp_idname as 
	select * from stage.select_temp_idname();

create or replace function stage.temp_idname_insert() returns trigger as $$
begin
	create temporary table if not exists test_temp_idname(id bigint, name varchar) on commit drop;
	insert into test_temp_idname(id, name) values (new.id, new.name);
	return new;
end;
$$ language plpgsql 
set client_min_messages to error 
set search_path to stage;

drop trigger if exists temp_idname_insert on stage.temp_idname;
create trigger temp_idname_insert 
	instead of insert on stage.temp_idname
	for each row
	execute procedure stage.temp_idname_insert();

explain insert into stage.temp_idname(id, name)
values (1,'one'), (2, 'two');

explain select * from stage.temp_idname;

select * from stage.temp_idname;

insert into stage.temp_idname(id, name)
values (1,'one'), (2, 'two');

select * from stage.temp_idname;

-- Cleaning up:
-- drop function if exists stage.select_temp_idname() cascade;
-- drop function if exists stage.temp_idname_insert();
