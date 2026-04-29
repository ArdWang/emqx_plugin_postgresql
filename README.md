# emqx_plugin_postgresql

EMQX plugin (for EMQX >= V5.4.1) that persists MQTT messages and client events to PostgreSQL.

## Usage

When using this plugin, please note:

- Erlang/OTP version in `.tool-versions` must not exceed 26
- rebar3 version in `.tool-versions` must not exceed 3.20
- Passwords in the config file are wrapped in closures by EMQX's HOCON system. The code handles this, but ensure correct format after manual config changes.

## Features

| Feature | Trigger | Destination Table |
|---------|---------|-------------------|
| **Telemetry Data** | Publish to `device/telemetry/#` topic | `sensor_data` |
| **Device Status** | Publish to `device/status/#` topic | `sensor_status` |
| **Connection Events** | Client connect/disconnect | `emqx_client_events` |

## Database Design

### 1. `sensor_data` — Telemetry Data Table

Stores device telemetry data (temperature, humidity, etc.). Each new message updates the latest data for that device.

```sql
CREATE TABLE IF NOT EXISTS sensor_data (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    ct DOUBLE PRECISION,
    ch DOUBLE PRECISION,
    ctc DOUBLE PRECISION,
    chc DOUBLE PRECISION,
    sensor_time TIMESTAMP
);

-- Unique constraint is required for upsert
ALTER TABLE sensor_data ADD CONSTRAINT uq_sensor_data_name UNIQUE (name);

CREATE INDEX IF NOT EXISTS idx_sensor_data_name ON sensor_data(name);
CREATE INDEX IF NOT EXISTS idx_sensor_data_sensor_time ON sensor_data(sensor_time);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGSERIAL | Auto-increment primary key |
| `name` | VARCHAR(255) | Device name (from payload `name` field), **unique constraint** |
| `ct` | DOUBLE PRECISION | Temperature value |
| `ch` | DOUBLE PRECISION | Humidity value |
| `ctc` | DOUBLE PRECISION | Temperature corrected value |
| `chc` | DOUBLE PRECISION | Humidity corrected value |
| `sensor_time` | TIMESTAMP | Sensor timestamp |

**Upsert Strategy**: `ON CONFLICT (name) DO UPDATE` — When a device has new data, all fields are updated.

### 2. `sensor_status` — Device Status Table

Stores device-reported status information (version, etc.). Each status message updates the latest state for that device.

```sql
CREATE TABLE IF NOT EXISTS sensor_status (
    name VARCHAR(255) PRIMARY KEY,
    version VARCHAR(255),
    sensor_time TIMESTAMP
);
```

| Column | Type | Description |
|--------|------|-------------|
| `name` | VARCHAR(255) | Device name (extracted from topic path `device/status/<name>/...`), **primary key** |
| `version` | VARCHAR(255) | Device version (from payload `version` field) |
| `sensor_time` | TIMESTAMP | Status timestamp |

**Upsert Strategy**: `ON CONFLICT (name) DO UPDATE` — When a device has new status, `version` and `sensor_time` are updated.

### 3. `emqx_client_events` — Client Events Table

Records device connect/disconnect events. Each clientid retains only the latest event state.

```sql
CREATE TABLE IF NOT EXISTS emqx_client_events (
    id BIGSERIAL PRIMARY KEY,
    clientid VARCHAR(255) NOT NULL,
    event VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE emqx_client_events ADD CONSTRAINT uq_clientid UNIQUE (clientid);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | BIGSERIAL | Auto-increment primary key |
| `clientid` | VARCHAR(255) | MQTT Client ID, **unique constraint** |
| `event` | VARCHAR(50) | Event type: `connected` or `disconnected` |
| `created_at` | TIMESTAMP | Event time (auto-filled with `CURRENT_TIMESTAMP`) |

**Upsert Strategy**: `ON CONFLICT (clientid) DO UPDATE` — When a client has a new event, `event` and `created_at` are updated.

## Message Format

### Telemetry Messages (`device/telemetry/#`)

**Topic**: Any topic starting with `device/telemetry/`

**Payload (JSON)**:
```json
{
  "name": "sensor_001",
  "ct": 25.6,
  "ch": 60.3,
  "ctc": 25.8,
  "chc": 60.1,
  "time": 1714370000000
}
```

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `name` | string | No | `"unknown"` |
| `ct` | number | No | `0.0` |
| `ch` | number | No | `0.0` |
| `ctc` | number | No | `0.0` |
| `chc` | number | No | `0.0` |
| `time` | number | No | Uses EMQX message timestamp |

### Status Messages (`device/status/#`)

**Topic**: Any topic starting with `device/status/`. Device name is auto-extracted from the topic path (e.g., `device/status/sensor_001/battery` → `sensor_001`)

**Payload (JSON)**:
```json
{
  "version": "v2.1.0",
  "sensor_time": 1714370000000
}
```

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `version` | string | No | `"unknown"` |
| `sensor_time` | number | No | Uses EMQX message timestamp |

### Connection Events

Automatically triggered by EMQX, no manual message publishing needed:
- Device connects → writes `{"clientid": "...", "event": "connected"}`
- Device disconnects → writes `{"clientid": "...", "event": "disconnected"}`

## Configuration

Edit `priv/emqx_plugin_postgresql.hocon`:

```hocon
plugin_postgresql {
  connection {
    server = "127.0.0.1:5432"     # PostgreSQL host:port
    database = "postgres"         # Database name
    username = "postgres"         # Username
    password = "postgres"         # Password
    ssl {
      enable = false              # Enable SSL
    }
    pool_size = 8                 # Connection pool size
    health_check_interval = 30s   # Health check interval
  }

  topics = [
    {
      name = telemetry_topic,     # Config name (internal identifier)
      filter = "device/telemetry/#",  # MQTT topic filter
      table = "sensor_data"       # Target database table
    },
    {
      name = status_topic,
      filter = "device/status/#",
      table = "sensor_status"
    }
  ]
}
```

## Build & Deployment

```bash
# Build
make rel

# Copy the generated plugin directory to EMQX's plugins directory
# _build/default/emqx_plugrel/
```

You can also specify a custom config file path via environment variable:

```bash
export EMQX_PLUGIN_POSTGRESQL_CONF=/path/to/custom.hocon
```

## Changelog (Bug Fixes)

### 1. Compilation Error: `head mismatch`

**File**: `src/emqx_plugin_postgresql.erl`, line 357

**Cause**: The last clause of `start_resource_if_enabled/1` ended with a semicolon `;` instead of a period `.`, causing the subsequent `query/1` function to be parsed as a clause of the same function.

**Fix**: Changed semicolon to period.

### 2. Password Authentication Failure: `invalid_password`

**File**: `src/emqx_plugin_postgresql_connector.erl`, `password_to_list/1`

**Cause**: EMQX's HOCON config system wraps password values in a closure via `emqx_schema_secret`: `fun() -> <<"password">> end`. The connector received a function instead of a string. `password_to_list/1` had no branch for function types, falling through to the default clause which returned an empty string `""`, causing PostgreSQL to reject the empty password.

**Fix**: Added function type matching:
```erlang
password_to_list(Fun) when is_function(Fun, 0) ->
    password_to_list(emqx_secret:unwrap(Fun));
```

### 3. Client Connect/Disconnect Events Not Triggered

**File**: `src/emqx_plugin_postgresql.erl`

**Cause**: EMQX >= V5.4.1 uses different hook callback signatures:
- `'client.connected'` callback is `(ClientInfo, ConnInfo)` → **2 arguments**
- `'client.disconnected'` callback is `(ClientInfo, Reason, ConnInfo)` → **3 arguments**

The original code defined `on_client_connected` as `/3` and `on_client_disconnected` as `/4`, so the hook was never called due to arity mismatch.

**Fix**:
- `on_client_connected/3` → `on_client_connected/2`
- `on_client_disconnected/4` → `on_client_disconnected/3`

### 4. `sensor_data` Table Not Replacing Data

**File**: `src/emqx_plugin_postgresql.erl`, `build_telemetry_sqls/2`

**Cause**: The original SQL only had `INSERT INTO ... VALUES` with no `ON CONFLICT` clause. Even when `ON CONFLICT (name, sensor_time)` was added, since each message has a different `sensor_time`, the conflict condition was never met — still insert-only behavior.

**Fix**: Changed to `ON CONFLICT (name) DO UPDATE` — new data for the same device overwrites old data:
```sql
INSERT INTO sensor_data (name, ct, ch, ctc, chc, sensor_time)
VALUES (...)
ON CONFLICT (name)
DO UPDATE SET ct = EXCLUDED.ct, ch = EXCLUDED.ch,
              ctc = EXCLUDED.ctc, chc = EXCLUDED.chc, sensor_time = EXCLUDED.sensor_time;
```

### 5. Connection Events Written to Wrong Table

**File**: `src/emqx_plugin_postgresql.erl`, `build_client_event_sqls/2`

**Cause**: The original code wrote connect/disconnect events to `sensor_status` (columns: `name, version, sensor_time`), but they should go to the dedicated events table `emqx_client_events` (columns: `clientid, event, created_at`).

**Fix**: SQL now writes to `emqx_client_events`:
```sql
INSERT INTO emqx_client_events (clientid, event, created_at)
VALUES ('client_xxx', 'connected', CURRENT_TIMESTAMP)
ON CONFLICT (clientid)
DO UPDATE SET event = EXCLUDED.event, created_at = EXCLUDED.created_at;
```

### 6. Config File Path Error

**File**: `src/emqx_plugin_postgresql.erl`, `postgresql_config_file/0`

**Cause**: The original code hardcoded the path to `etc/emqx_plugin_postgresql.hocon`, but the plugin actually ships its config in the `priv/` directory.

**Fix**: Reads from `priv/` first, falls back to `etc/`:
```erlang
postgresql_config_file() ->
  case os:getenv("EMQX_PLUGIN_POSTGRESQL_CONF") of
    "" | false ->
      PrivDir = code:priv_dir(?MODULE),
      PrivConf = filename:join([PrivDir, "emqx_plugin_postgresql.hocon"]),
      case filelib:is_regular(PrivConf) of
        true -> PrivConf;
        false -> "etc/emqx_plugin_postgresql.hocon"
      end;
    Env -> Env
  end.
```
