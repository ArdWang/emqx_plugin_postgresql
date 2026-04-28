-- PostgreSQL tables for EMQX plugin
-- Run this script to create the required tables before using the plugin.

CREATE TABLE IF NOT EXISTS sensor_data (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    ct DOUBLE PRECISION,
    ch DOUBLE PRECISION,
    ctc DOUBLE PRECISION,
    chc DOUBLE PRECISION,
    sensor_time TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sensor_data_name ON sensor_data(name);
CREATE INDEX IF NOT EXISTS idx_sensor_data_sensor_time ON sensor_data(sensor_time);

CREATE TABLE IF NOT EXISTS sensor_status (
    name VARCHAR(255) PRIMARY KEY,
    version VARCHAR(255),
    sensor_time TIMESTAMP
);
