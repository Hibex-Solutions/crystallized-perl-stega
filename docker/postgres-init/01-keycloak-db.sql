-- Cria a database do Keycloak no mesmo PostgreSQL da aplicação.
-- Este script é executado automaticamente pelo container postgres na primeira
-- inicialização (docker-entrypoint-initdb.d). Em volumes já existentes é ignorado.
CREATE DATABASE keycloak;
