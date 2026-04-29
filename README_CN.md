# emqx_plugin_postgresql

EMQX 插件（适用于 EMQX >= V5.4.1），将 MQTT 消息与客户端事件持久化到 PostgreSQL。

## 使用说明

使用此插件时，请注意：

- `.tool-versions` 中 Erlang/OTP 版本不能超过 26
- `.tool-versions` 中 rebar3 版本不能超过 3.20
- 配置文件中的密码会被 EMQX HOCON 系统包装成闭包，代码已处理此问题，但手动修改配置后需确保格式正确

## 功能

| 功能 | 触发方式 | 写入表 |
|------|---------|--------|
| **遥测数据** | 发布 `device/telemetry/#` 主题消息 | `sensor_data` |
| **设备状态** | 发布 `device/status/#` 主题消息 | `sensor_status` |
| **连接事件** | 客户端连接/断开 | `emqx_client_events` |

## 数据库设计

### 1. `sensor_data` — 遥测数据表

存储设备遥测数据（温度、湿度等），每条新消息更新同一设备的最新数据。

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

-- 唯一约束是 upsert 的前提，必须创建
ALTER TABLE sensor_data ADD CONSTRAINT uq_sensor_data_name UNIQUE (name);

CREATE INDEX IF NOT EXISTS idx_sensor_data_name ON sensor_data(name);
CREATE INDEX IF NOT EXISTS idx_sensor_data_sensor_time ON sensor_data(sensor_time);
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | BIGSERIAL | 自增主键 |
| `name` | VARCHAR(255) | 设备名称（来自 payload 中的 `name` 字段），**唯一约束** |
| `ct` | DOUBLE PRECISION | 温度值 |
| `ch` | DOUBLE PRECISION | 湿度值 |
| `ctc` | DOUBLE PRECISION | 温度校正值 |
| `chc` | DOUBLE PRECISION | 湿度校正值 |
| `sensor_time` | TIMESTAMP | 传感器时间戳 |

**upsert 策略**：`ON CONFLICT (name) DO UPDATE` — 同一设备有新数据时，更新该设备的所有字段。

### 2. `sensor_status` — 设备状态表

存储设备上报的状态信息（版本号等），每条状态消息更新同一设备的最新状态。

```sql
CREATE TABLE IF NOT EXISTS sensor_status (
    name VARCHAR(255) PRIMARY KEY,
    version VARCHAR(255),
    sensor_time TIMESTAMP
);
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | VARCHAR(255) | 设备名称（从主题路径 `device/status/<name>/...` 提取），**主键** |
| `version` | VARCHAR(255) | 设备版本号（来自 payload 中的 `version` 字段） |
| `sensor_time` | TIMESTAMP | 状态时间戳 |

**upsert 策略**：`ON CONFLICT (name) DO UPDATE` — 同一设备有新状态时，更新 `version` 和 `sensor_time`。

### 3. `emqx_client_events` — 客户端事件表

记录设备连接/断开事件，同一 clientid 只保留最新事件状态。

```sql
CREATE TABLE IF NOT EXISTS emqx_client_events (
    id BIGSERIAL PRIMARY KEY,
    clientid VARCHAR(255) NOT NULL,
    event VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE emqx_client_events ADD CONSTRAINT uq_clientid UNIQUE (clientid);
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | BIGSERIAL | 自增主键 |
| `clientid` | VARCHAR(255) | MQTT 客户端 ID，**唯一约束** |
| `event` | VARCHAR(50) | 事件类型：`connected`（连接）或 `disconnected`（断开） |
| `created_at` | TIMESTAMP | 事件发生时间（自动填充 `CURRENT_TIMESTAMP`） |

**upsert 策略**：`ON CONFLICT (clientid) DO UPDATE` — 同一客户端有新事件时，更新 `event` 和 `created_at`。

## 消息格式

### 遥测消息（`device/telemetry/#`）

**主题**：`device/telemetry/` 开头的任意主题

**Payload（JSON）**：
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

| 字段 | 类型 | 必需 | 默认值 |
|------|------|------|--------|
| `name` | string | 否 | `"unknown"` |
| `ct` | number | 否 | `0.0` |
| `ch` | number | 否 | `0.0` |
| `ctc` | number | 否 | `0.0` |
| `chc` | number | 否 | `0.0` |
| `time` | number | 否 | 使用 EMQX 消息时间戳 |

### 状态消息（`device/status/#`）

**主题**：`device/status/` 开头的任意主题，设备名从主题路径中自动提取（如 `device/status/sensor_001/battery` → `sensor_001`）

**Payload（JSON）**：
```json
{
  "version": "v2.1.0",
  "sensor_time": 1714370000000
}
```

| 字段 | 类型 | 必需 | 默认值 |
|------|------|------|--------|
| `version` | string | 否 | `"unknown"` |
| `sensor_time` | number | 否 | 使用 EMQX 消息时间戳 |

### 连接事件

由 EMQX 自动触发，无需手动发布消息：
- 设备连接 → 写入 `{"clientid": "...", "event": "connected"}`
- 设备断开 → 写入 `{"clientid": "...", "event": "disconnected"}`

## 配置文件

编辑 `priv/emqx_plugin_postgresql.hocon`：

```hocon
plugin_postgresql {
  connection {
    server = "127.0.0.1:5432"     # PostgreSQL 地址:端口
    database = "postgres"         # 数据库名
    username = "postgres"         # 用户名
    password = "postgres"         # 密码
    ssl {
      enable = false              # 是否启用 SSL
    }
    pool_size = 8                 # 连接池大小
    health_check_interval = 30s   # 健康检查间隔
  }

  topics = [
    {
      name = telemetry_topic,     # 配置名称（内部标识）
      filter = "device/telemetry/#",  # MQTT 主题过滤器
      table = "sensor_data"       # 写入的数据库表名
    },
    {
      name = status_topic,
      filter = "device/status/#",
      table = "sensor_status"
    }
  ]
}
```

## 编译与部署

```bash
# 编译
make rel

# 将生成的插件目录复制到 EMQX 的 plugins 目录
# _build/default/emqx_plugrel/
```

也可以通过环境变量指定配置文件路径：

```bash
export EMQX_PLUGIN_POSTGRESQL_CONF=/path/to/custom.hocon
```

## 修改记录（修复清单）

### 1. 编译错误：`head mismatch`

**文件**：`src/emqx_plugin_postgresql.erl`，第 357 行

**原因**：`start_resource_if_enabled/1` 最后一个子句末尾使用了分号 `;`，导致后续 `query/1` 函数被当作同一函数的子句。

**修复**：分号改为句号 `.`。

### 2. 密码认证失败：`invalid_password`

**文件**：`src/emqx_plugin_postgresql_connector.erl`，`password_to_list/1`

**原因**：EMQX 的 HOCON 配置系统通过 `emqx_schema_secret` 模块将密码值包装成一个闭包 `fun() -> <<"password">> end`。连接器拿到的是函数而非字符串。`password_to_list/1` 没有处理函数类型的分支，走到默认子句返回了空字符串 `""`，导致 PostgreSQL 收到空密码报 `invalid_password`。

**修复**：添加函数类型匹配：
```erlang
password_to_list(Fun) when is_function(Fun, 0) ->
    password_to_list(emqx_secret:unwrap(Fun));
```

### 3. 客户端连接/断开事件不触发

**文件**：`src/emqx_plugin_postgresql.erl`

**原因**：EMQX >= V5.4.1 的 hook 回调签名与早期版本不同：
- `'client.connected'` 的回调签名是 `(ClientInfo, ConnInfo)` → **2 个参数**
- `'client.disconnected'` 的回调签名是 `(ClientInfo, Reason, ConnInfo)` → **3 个参数**

原代码 `on_client_connected` 定义为 `/3`、`on_client_disconnected` 定义为 `/4`，参数个数不匹配导致 hook 永远不会被调用。

**修复**：
- `on_client_connected/3` → `on_client_connected/2`
- `on_client_disconnected/4` → `on_client_disconnected/3`

### 4. `sensor_data` 表数据不替换

**文件**：`src/emqx_plugin_postgresql.erl`，`build_telemetry_sqls/2`

**原因**：原始 SQL 只有 `INSERT INTO ... VALUES`，没有 `ON CONFLICT` 子句。即使后来添加了 `ON CONFLICT (name, sensor_time)`，由于每次消息的 `sensor_time` 都不同，冲突条件永远不满足，仍然只插入不更新。

**修复**：改为 `ON CONFLICT (name) DO UPDATE` — 同一设备有新数据时覆盖旧数据：
```sql
INSERT INTO sensor_data (name, ct, ch, ctc, chc, sensor_time)
VALUES (...)
ON CONFLICT (name)
DO UPDATE SET ct = EXCLUDED.ct, ch = EXCLUDED.ch,
              ctc = EXCLUDED.ctc, chc = EXCLUDED.chc, sensor_time = EXCLUDED.sensor_time;
```

### 5. 连接事件写入了错误的表

**文件**：`src/emqx_plugin_postgresql.erl`，`build_client_event_sqls/2`

**原因**：原代码将连接/断开事件写入 `sensor_status` 表（字段为 `name, version, sensor_time`），但实际应该写入专用的事件表 `emqx_client_events`（字段为 `clientid, event, created_at`）。

**修复**：SQL 改为写入 `emqx_client_events` 表：
```sql
INSERT INTO emqx_client_events (clientid, event, created_at)
VALUES ('client_xxx', 'connected', CURRENT_TIMESTAMP)
ON CONFLICT (clientid)
DO UPDATE SET event = EXCLUDED.event, created_at = EXCLUDED.created_at;
```

### 6. 配置文件路径错误

**文件**：`src/emqx_plugin_postgresql.erl`，`postgresql_config_file/0`

**原因**：原代码硬编码路径为 `etc/emqx_plugin_postgresql.hocon`（EMQX 安装目录），但插件实际将配置文件放在 `priv/` 目录下。

**修复**：优先从插件 `priv/` 目录读取，找不到才降级到 `etc/` 目录：
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
