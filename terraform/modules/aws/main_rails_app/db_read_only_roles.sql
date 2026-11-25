-- Read-only database roles for people and agents (docs/db-read-only-access.md).
--
-- Run by the Kubernetes Job in db_read_only_access.tf as the master user,
-- connected to the app database, with psql variables:
--   group_role      NOLOGIN role that holds the grants
--   ci_role         login role for the read-only CI role (CI and agents)
--   infra_eng_role  login role for the InfraEng permission sets
--   connection_limit
--
-- Every statement can be run again: the Job re-runs whenever this file, its
-- variables or the database instance change.

\set ON_ERROR_STOP on

-- 1. The roles. No password is ever set: membership of rds_iam makes RDS
--    accept only a short-lived IAM token for the role, over TLS.
SELECT format('CREATE ROLE %I NOLOGIN', :'group_role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'group_role') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'ci_role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'ci_role') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'infra_eng_role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'infra_eng_role') \gexec

ALTER ROLE :"group_role" WITH NOLOGIN NOCREATEDB NOCREATEROLE;
ALTER ROLE :"ci_role" WITH LOGIN NOCREATEDB NOCREATEROLE INHERIT CONNECTION LIMIT :connection_limit;
ALTER ROLE :"infra_eng_role" WITH LOGIN NOCREATEDB NOCREATEROLE INHERIT CONNECTION LIMIT :connection_limit;

GRANT rds_iam TO :"ci_role", :"infra_eng_role";
GRANT :"group_role" TO :"ci_role", :"infra_eng_role";

-- 2. Session defaults. These are guard rails, not the security boundary (a
--    session can change them); the grants below are the boundary. They keep
--    an observer from hurting the database it is looking at: a SELECT holds
--    an ACCESS SHARE lock, which blocks a migration's DDL for as long as the
--    statement or an idle open transaction lasts.
ALTER ROLE :"ci_role" SET default_transaction_read_only = on;
ALTER ROLE :"ci_role" SET statement_timeout = '30s';
ALTER ROLE :"ci_role" SET lock_timeout = '5s';
ALTER ROLE :"ci_role" SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE :"ci_role" SET idle_session_timeout = '30min';
ALTER ROLE :"infra_eng_role" SET default_transaction_read_only = on;
ALTER ROLE :"infra_eng_role" SET statement_timeout = '30s';
ALTER ROLE :"infra_eng_role" SET lock_timeout = '5s';
ALTER ROLE :"infra_eng_role" SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE :"infra_eng_role" SET idle_session_timeout = '30min';

-- 2b. Who did what: log every statement these two roles run. The RDS log
--    line prefix carries the user name, so the PostgreSQL log attributes each
--    statement to the infra-eng or the CI role. log_statement is a
--    superuser-level setting that rds_superuser is allowed to set per role;
--    if an engine version ever refuses it, the roles must still be created,
--    so an error here is reported and skipped. The report at the end shows
--    whether the setting is in place.
\set ON_ERROR_STOP off
ALTER ROLE :"ci_role" SET log_statement = 'all';
ALTER ROLE :"infra_eng_role" SET log_statement = 'all';
\set ON_ERROR_STOP on

-- 3. Close what PUBLIC (every role) gets by default, so that "read-only" is
--    true. The app connects as the owner of the database and of the schema,
--    and an owner keeps its rights whatever PUBLIC has.
--    - CREATE on schema public: the database predates PostgreSQL 15, where
--      every role could create tables there.
--    - TEMPORARY and CONNECT on the app database: connect is granted back to
--      the group role only.
--    - CONNECT on postgres and template1: nothing to read there, and their
--      public schemas are writable by every role in the same way.
SELECT current_database() AS app_database \gset
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE :"app_database" FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

-- 4. What the read-only roles can see: the tables, views and sequences the
--    app has in schema public, and whatever a later migration adds there.
--    No membership of rds_superuser, pg_monitor, pg_read_all_data,
--    pg_read_all_stats or pg_signal_backend, and no access to the rdsadmin
--    database.
GRANT CONNECT ON DATABASE :"app_database" TO :"group_role";
GRANT USAGE ON SCHEMA public TO :"group_role";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"group_role";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"group_role";
-- Default privileges of the role running this file, which is the role the
-- app's migrations run as.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"group_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO :"group_role";

-- 5. Report, so the Job's log shows the result.
SELECT r.rolname, r.rolcanlogin, r.rolconnlimit,
       (SELECT string_agg(g.rolname, ', ' ORDER BY g.rolname)
          FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
         WHERE m.member = r.oid) AS member_of,
       COALESCE((SELECT bool_or(c LIKE 'log_statement=all')
                   FROM pg_db_role_setting s, unnest(s.setconfig) AS c
                  WHERE s.setrole = r.oid), false) AS statements_logged
  FROM pg_roles r
 WHERE r.rolname IN (:'group_role', :'ci_role', :'infra_eng_role')
 ORDER BY 1;
