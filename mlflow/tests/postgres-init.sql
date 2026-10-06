-- The two databases of the production setup, each with its own owner
-- (see "PostgreSQL" in ../README.md). Run once by the postgres image on
-- first start, from /docker-entrypoint-initdb.d/.
CREATE USER mlflow WITH PASSWORD 'mlflow';
CREATE USER mlflow_auth WITH PASSWORD 'mlflow_auth';
CREATE DATABASE mlflow OWNER mlflow;
CREATE DATABASE mlflow_auth OWNER mlflow_auth;
