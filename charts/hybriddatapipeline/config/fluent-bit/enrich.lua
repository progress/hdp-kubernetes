-- ═══════════════════════════════════════════════════════════════
-- HDP Centralized Logging — Enrichment Script
--
-- Canonical path: otel-hdp-logs/config/fluent-bit/enrich.lua
-- Vendored copies are kept in sync by
--   scripts/sync-fluent-bit-config.{sh,ps1}   (P2-20, P3-32)
-- ═══════════════════════════════════════════════════════════════

-- Map log level strings to OTel severity numbers.
-- Used by both JULI (uppercase) and procrun (lowercase) levels.
local severity_map = {
    SEVERE  = 17, -- ERROR
    WARNING = 13, -- WARN
    INFO    = 9,  -- INFO
    CONFIG  = 5,  -- DEBUG
    FINE    = 5,  -- DEBUG
    FINER   = 1,  -- TRACE
    FINEST  = 1,  -- TRACE
    ERROR   = 17,
    WARN    = 13,
    DEBUG   = 5,
    TRACE   = 1,
    -- procrun uses lowercase levels
    error   = 17,
    warn    = 13,
    info    = 9,
    debug   = 5,
}

-- ── Month name → number lookup ───────────────────────────────
local month_map = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4,  May = 5,  Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- ── UTC epoch helper (P0-3) ──────────────────────────────────
-- Lua's os.time() interprets table fields as LOCAL time. On a host
-- with TZ != UTC, every parsed deploy timestamp would be off by
-- the local offset, breaking the Grafana time picker and Loki
-- ordering. utc_time() compensates by computing the local/UTC
-- delta so the returned epoch is always seconds-since-1970-UTC.
local function utc_time(t)
    local local_epoch = os.time(t)
    if not local_epoch then return nil end
    local utc_epoch   = os.time(os.date("!*t", local_epoch))
    return local_epoch + (local_epoch - utc_epoch)
end

-- ── Bounded cache helper (P1-11) ──────────────────────────────
-- Keeps a plain table from growing without bound in long-running
-- Fluent Bit processes (e.g. K8s pod churn). Reads stay as
-- `tbl[k]` so existing callsites do not change. Writes go through
-- `bset(tbl, order, k, v)` which evicts the oldest inserted key
-- once the cap is exceeded. Cap configurable via FB_LUA_CACHE_MAX
-- (default 10 000).
local CACHE_MAX = tonumber(os.getenv("FB_LUA_CACHE_MAX")) or 10000

local function bset(tbl, order, k, v)
    if tbl[k] == nil then
        order[#order + 1] = k
        if #order > CACHE_MAX then
            local oldest = table.remove(order, 1)
            if oldest ~= nil then tbl[oldest] = nil end
        end
    end
    tbl[k] = v
end


-- ── Deploy timestamp cache (P1-11 bounded) ───────────────────
-- Keyed by hostname, stores the latest Java timestamp parsed from
-- deploy.log for that host. Used both as an attribute
-- (hdp.deploy.timestamp) for dashboard display and as the record
-- timestamp for follow-on records (error, final, properties).
local deploy_ts_cache       = {}
local deploy_ts_order       = {}
-- ── Cluster cache (P1-11 bounded) ────────────────────────────
-- Keyed by hostname, stores the EXTERNAL_HOST_NAME from
-- update.properties. Becomes a Loki index label (cluster_name).
local cluster_cache         = {}
local cluster_order         = {}
local host_dir_cache        = {}
local host_dir_order        = {}
-- ── Per-host line counters (P1-12) ────────────────────────────
-- Records without distinct timestamps need nanosecond offsets to
-- prevent Loki from collapsing entries at the same timestamp.
-- P1-12 FIX: counters are now per-host (not global) so concurrent
-- hosts do not collide and do not waste offsets across each other.
local error_line_counter    = {}
local error_line_order      = {}
local final_line_counter    = {}
local final_line_order      = {}

local function bump(counter_tbl, order_tbl, hostname)
    local n = (counter_tbl[hostname] or 0) + 1
    bset(counter_tbl, order_tbl, hostname, n)
    return n
end


-- Parse a Java US-locale timestamp: "Jun 04, 2025 7:26:59 AM"
-- Returns a Fluent Timestamp table {sec=, nsec=} or nil.
local function parse_java_us_timestamp(msg)
    local mon_s, day, year, hour, min, sec, ampm = string.match(
        msg, "(%a%a%a)%s+(%d%d),%s+(%d%d%d%d)%s+(%d+):(%d%d):(%d%d)%s+([AP]M)")
    if not mon_s then return nil end

    local mon = month_map[mon_s]
    if not mon then return nil end

    hour = tonumber(hour)
    -- P3-29: AM/PM hours are 1..12. Reject anything outside that
    -- range — a 13:xx PM or 00:xx AM means the upstream line is
    -- malformed (or someone fed a 24h timestamp into this parser),
    -- and silently coercing it would shift the record by 12 hours.
    if not hour or hour < 1 or hour > 12 then return nil end
    if ampm == "PM" and hour ~= 12 then hour = hour + 12 end
    if ampm == "AM" and hour == 12 then hour = 0 end

    -- P0-3 FIX: use utc_time() so the result is correct regardless
    -- of the FB host's local timezone. The original os.time() call
    -- silently returned a local epoch on non-UTC hosts.
    local epoch = utc_time({
        year  = tonumber(year),
        month = mon,
        day   = tonumber(day),
        hour  = hour,
        min   = tonumber(min),
        sec   = tonumber(sec),
    })
    return epoch
end

-- ═══════════════════════════════════════════════════════════════
-- Resolve cluster name (EXTERNAL_HOST_NAME) for a given hostname.
-- Reads update.properties from disk on first encounter, then caches.
-- Called from enrich_with_hostname() for every log record.
--
-- Lookup strategy:
--   1. Return cached value if already resolved
--   2. Derive host directory from the record's _file path
--   3. Read update.properties from that directory
--   4. Extract EXTERNAL_HOST_NAME value and cache it
--
-- For hosts without update.properties (e.g., OPC standalone),
-- returns nil and the record will have no cluster.name attribute.
-- ═══════════════════════════════════════════════════════════════

-- Add a cache for failed attempts to prevent tight I/O loops during startup
-- (P1-11 bounded)
local failed_lookup_cache = {}
local failed_lookup_order = {}
local RECHECK_DELAY_SECONDS = 10

-- P1-10: bound deploy.log scan to a fixed read budget so a
-- multi-megabyte deploy.log on slow PVC storage cannot stall the
-- pipeline thread on the first record per host.
local DEPLOY_SCAN_BYTES = 65536

-- P0-4 FIX: declared `local` to avoid leaking into the global table.
-- Only the entry-point functions referenced by `call:` directives in
-- fluent-bit.yaml need to be globals.
local function resolve_cluster(hostname, file_path)
    -- Already cached?
    local cached = cluster_cache[hostname]
    if cached then return cached end

    -- If we recently failed, don't hit the disk again yet
    local last_fail = failed_lookup_cache[hostname]
    if last_fail and (os.time() - last_fail) < RECHECK_DELAY_SECONDS then
        return nil
    end

    -- Derive host directory from file path
    local host_dir = host_dir_cache[hostname]
    if not host_dir then
        -- Extract path up to hostname directory.
        -- Escape regex-special chars in hostname (dots, hyphens, etc.)
        local escaped_host = hostname:gsub("([%.%-%+%[%]%(%)%$%^])", "%%%1")
        host_dir = string.match(file_path, "(.-/" .. escaped_host .. ")/")
        if host_dir then bset(host_dir_cache, host_dir_order, hostname, host_dir) end
    end

    if not host_dir then
        return nil
    end

    -- Try to read update.properties from the host directory
    local props_path = host_dir .. "/update.properties"
    local f = io.open(props_path, "r")
    if f then
        for line in f:lines() do
            local value = string.match(line, "^EXTERNAL_HOST_NAME=(.+)$")
            if value then
                value = value:gsub("%s+$", "")
                bset(cluster_cache, cluster_order, hostname, value)
                f:close()
                return value
            end
        end
        f:close()
    end

    -- Fallback: scan up to DEPLOY_SCAN_BYTES of deploy.log for
    -- EXTERNAL_HOST_NAME (P1-10).  deploy.log can be megabytes;
    -- a full scan on the pipeline thread would stall every input.
    local deploy_path = host_dir .. "/install/deploy.log"
    f = io.open(deploy_path, "r")
    if f then
        local chunk = f:read(DEPLOY_SCAN_BYTES) or ""
        f:close()
        local in_final = false
        for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
            if string.find(line, "Writing properties to") and string.find(line, "update.properties") then
                in_final = true
            end
            if in_final then
                local value = string.match(line, "^EXTERNAL_HOST_NAME=(.+)$")
                if value then
                    value = value:gsub("%s+$", "")
                    if value ~= "" then
                        bset(cluster_cache, cluster_order, hostname, value)
                        return value
                    end
                end
            end
        end
    end

    -- Record the failure to prevent I/O thrashing for RECHECK_DELAY_SECONDS
    bset(failed_lookup_cache, failed_lookup_order, hostname, os.time())
    return nil
end

-- ── enrich_with_hostname ──────────────────────────────────────
-- Main enrichment function. Adds host.name, hdp.component,
-- service.name, and severity_number to every record.
-- Also triggers session metadata extraction for DAS-tagged records.
--
-- Usage in fluent-bit.yaml:
--   [FILTER]
--       Name    lua
--       Match   *
--       Script  enrich.lua
--       Call    enrich_with_hostname
--
function enrich_with_hostname(tag, timestamp, record)
    local new_record = record

    -- ── Extract hostname ──────────────────────────────────────
    -- Supports both flat and nested layouts:
    --   Flat:   /logs/<hostname>/das/...           => hostname
    --   Nested: /logs/<group>/<hostname>/das/...   => hostname
    --   OPC:    /logs/opc-logs/catalina.*.log      => opc-logs
    --   OPC:    /logs/<group>/opc-logs-*/das/...   => opc-logs-*
    -- Strategy: extract the directory component immediately before
    -- a known log-type subdirectory (das/, tomcat/, hdpui/, install/,
    -- notification/). For root-level files (OPC flat, update.properties),
    -- fall back to the last directory component before the filename.
    local path = record["_file"] or ""
    local hostname = string.match(path, "([^/]+)/das/")
                  or string.match(path, "([^/]+)/tomcat/")
                  or string.match(path, "([^/]+)/hdpui/")
                  or string.match(path, "([^/]+)/install/")
                  or string.match(path, "([^/]+)/notification/")
    if not hostname then
        -- Root-level files: pick last directory before filename
        -- e.g. /logs/opc-logs/catalina.*.log => opc-logs
        -- e.g. /logs/das-daily/opc-logs-5.0.0/catalina.*.log => opc-logs-5.0.0
        local dir = string.match(path, "([^/]+)/[^/]+$")
        if dir and dir ~= "logs" then
            hostname = dir
        end
    end
    if not hostname then
        -- Windows OPC or unknown path layout — use env or fallback
        hostname = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "opc-unknown"
    end
    new_record["host.name"] = hostname

    -- ── Classify component from Fluent Bit tag ───────────────
    if string.find(tag, "hdp.opc.accessor") then
        new_record["hdp.component"] = "opc-accessor"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.opc.procrun") then
        new_record["hdp.component"] = "opc-procrun"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.opc.das") then
        new_record["hdp.component"] = "opc-das"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.opc.tomcat") then
        new_record["hdp.component"] = "opc-tomcat"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.opc.stdout") then
        new_record["hdp.component"] = "opc-stdout"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.opc.access") then
        new_record["hdp.component"] = "opc-access"
        new_record["service.name"] = "hdp-opc"
    elseif string.find(tag, "hdp.das") then
        new_record["hdp.component"] = "das"
    elseif string.find(tag, "hdp.catalina_out") then
        -- catalina.out is the JVM/Spring Boot stdout file — distinct parser and content
        -- but belongs to the same "tomcat" component group as JULI rotation files.
        new_record["hdp.component"] = "tomcat"
        new_record["hdp.log_type"]  = "catalina_out"
    elseif string.find(tag, "hdp.tomcat") then
        -- JULI rotation files: catalina.YYYY-MM-DD.log, localhost.YYYY-MM-DD.log
        new_record["hdp.component"] = "tomcat"
        new_record["hdp.log_type"]  = "catalina_rotation"
    elseif string.find(tag, "hdp.access") then
        new_record["hdp.component"] = "access"
    elseif string.find(tag, "hdp.shutdown") then
        -- shutdown.log lives in the tomcat/ directory; same component group.
        -- Use hdp.log_type to distinguish it from catalina* logs at query time.
        new_record["hdp.component"] = "tomcat"
        new_record["hdp.log_type"]  = "shutdown"
    elseif string.find(tag, "hdp.hdpui") then
        new_record["hdp.component"] = "hdpui"
    elseif string.find(tag, "hdp.notification") then
        new_record["hdp.component"] = "notification"
    elseif string.find(tag, "hdp.install.schema") then
        -- Must come before the generic hdp.install match below.
        new_record["hdp.component"] = "install"
        new_record["hdp.log_type"]  = "schema"
    elseif string.find(tag, "hdp.install.debug") then
        -- Must come before the generic hdp.install match below.
        new_record["hdp.component"] = "install"
        new_record["hdp.log_type"]  = "debug"
    elseif string.find(tag, "hdp.install") then
        -- deploy/error/final sub-types: hdp.log_type set by enrich_deploy_log / enrich_error_log /
        -- enrich_final_log functions which run later in enrich_with_hostname.
        new_record["hdp.component"] = "install"
    else
        new_record["hdp.component"] = "unknown"
    end

    -- Set service.name default for server if not already set by OPC branch
    if not new_record["service.name"] then
        new_record["service.name"] = "hdp-server"
    end

    -- ── Resolve cluster name ─────────────────────────────────
    -- Guard: modify filter already stamps hdp.cluster from ${HDP_CLUSTER}
    -- (loadbalancer.hostName) on K8s. Skip disk I/O in that case.
    -- On-premise paths without modify filter still use resolve_cluster().
    if not new_record["hdp.cluster"] or new_record["hdp.cluster"] == "" then
        local cluster = resolve_cluster(hostname, path)
        if cluster then
            new_record["hdp.cluster"] = cluster
        end
    end

    -- ── Map log level to OTel severity number ────────────────
    local level = record["level"] or ""
    new_record["severity_number"] = severity_map[level] or 0

    -- ── Ensure message field exists ──────────────────────────
    -- Required for Fluent Bit's OTLP output: logs_body_key: $message
    -- extracts 'message' as the log body and sends remaining fields
    -- as log attributes. Records without 'message' (unparsed raw
    -- lines) would fall back to Map body with NO attributes, causing
    -- service.name/host.name to be lost. Copy 'log' → 'message'
    -- as fallback.
    if not new_record["message"] then
        new_record["message"] = new_record["log"] or ""
    end

    -- ── DAS Session Metadata Extraction (Family C) ───────────
    -- For DAS session logs, extract structured metadata from filepath
    -- and from the log body (source + message fields).
    if string.find(tag, "hdp.das") or string.find(tag, "hdp.opc.das") then
        extract_session_metadata(new_record)
    end

    -- ── OPC Connector Identity Extraction ────────────────────
    -- For OPC accessor logs, extract connector identity from the
    -- Java Map.toString() config block and DeviceId creation lines.
    -- For DAS logs, extract server-side OPC connection events
    -- (makeHostConnection with connectorId and connector-name).
    if string.find(tag, "hdp.opc.accessor") then
        enrich_opc_accessor(new_record)
    elseif string.find(tag, "hdp.das") and not string.find(tag, "hdp.opc.das") then
        enrich_opc_server_side(new_record)
    end

    -- ── Install Log Enrichment ───────────────────────────────
    -- For deploy/error/final/properties, use REAL deployment timestamps
    -- so the Grafana time picker correctly filters by deployment date.
    -- deploy.log: uses parser-extracted timestamps (e.g. Jun 04, 2025)
    -- error/final/properties: use cached deploy timestamp from same host.
    -- Loki handles out-of-order writes (unordered_writes: true).
    local new_ts = nil
    if string.find(tag, "hdp.install.deploy") then
        new_ts = enrich_deploy_log(new_record, hostname, timestamp)
    elseif string.find(tag, "hdp.install.error") then
        new_ts = enrich_error_log(new_record, hostname, timestamp)
    elseif string.find(tag, "hdp.install.final") then
        new_ts = enrich_final_log(new_record, hostname)
    end

    if new_ts then
        return 1, new_ts, new_record
    end

    return 1, timestamp, new_record
end

-- ═══════════════════════════════════════════════════════════════
-- Extract HDP session metadata from DAS session log filenames
-- and log body fields. Called from enrich_with_hostname() for
-- all DAS-tagged records.
--
-- From _file path (4 bracket segments in filename):
--   hdp.tenant, hdp.user, hdp.datastore, hdp.datasource
--
-- From source/message fields (log body):
--   hdp.trace_id  — from [trace=UUID]
--   hdp.operation — from .[operation] segment
-- ═══════════════════════════════════════════════════════════════
function extract_session_metadata(record)
    local path = record["_file"] or ""
    local filename = string.match(path, "/([^/]+)$") or ""

    -- ── DAS Log Type Classification ──────────────────────────
    -- Classify the DAS sub-log type from the filename pattern.
    -- Stored as hdp.log_type for efficient dashboard filtering.
    -- clouddb/filter/meter are included by default (DAS_EXCLUDE_PATH
    -- is empty) and classified here so dashboards can filter them
    -- at query time: | hdp_log_type != `clouddb` etc.
    -- NOTE: ddcloud/extauth/onpremise have no dedicated dashboard panels
    -- and fall through to "general"; distinguish by filename if needed.
    if string.find(filename, "^clouddb%.") then
        record["hdp.log_type"] = "clouddb"
    elseif string.find(filename, "^filter%.") then
        record["hdp.log_type"] = "filter"
    elseif string.find(filename, "^meter%.") then
        record["hdp.log_type"] = "meter"
    elseif string.find(filename, "das%-monitor") then
        record["hdp.log_type"] = "das-monitor"
    elseif string.find(filename, "%[system%]") then
        record["hdp.log_type"] = "system"
    elseif string.find(filename, "%[background%]") then
        record["hdp.log_type"] = "background"
    elseif string.find(filename, "%[messaging%]") then
        record["hdp.log_type"] = "messaging"
    end

    -- Extract 4-segment metadata from filename:
    -- e.g., /logs/hdp-1/das/[docker-cluster-tenant][saml_dslog_user][oracle][dslog_test_123].2026-02-19.log
    local tenant, user, datastore, datasource = string.match(path,
        "%[([^%]]+)%]%[([^%]]+)%]%[([^%]]+)%]%[([^%]]+)%]%.%d%d%d%d%-%d%d%-%d%d%.log$")
    if tenant then
        record["hdp.tenant"]     = tenant
        record["hdp.user"]       = user
        record["hdp.datastore"]  = datastore
        record["hdp.datasource"] = datasource
        if not record["hdp.log_type"] then
            record["hdp.log_type"] = "session"
        end
    end

    -- Default log type for unclassified DAS logs
    if not record["hdp.log_type"] then
        record["hdp.log_type"] = "general"
    end

    -- Extract trace_id from [trace=UUID] in source or message fields
    local source = record["source"] or ""
    local message = record["message"] or ""
    local trace_id = string.match(source, "%[trace=([^%]]+)%]")
                  or string.match(message, "%[trace=([^%]]+)%]")
    if trace_id then
        record["trace_id"] = trace_id
    end

    -- Extract operation from .[operation] segment
    -- Pattern: ].[operationName] — dot after closing bracket, before opening bracket
    local combined = source .. " " .. message
    local operation = string.match(combined, "%]%.%[([^%]]+)%]")
    if operation then
        record["hdp.operation"] = operation
    end
end

-- NOTE: DAS Monitor JVM metrics (heap, CPU, threads, GC, connection pools)
-- are now extracted at query-time using LogQL regexp patterns in Grafana.
-- This avoids inflating every das-monitor record with 23 extra attributes.
-- See hdp-system-health.json for the query-time extraction patterns.

-- ═══════════════════════════════════════════════════════════════
-- Enrich OPC Accessor logs with connector identity metadata.
-- Parses two log patterns:
--
-- 1) Config block (Java Map.toString()):
--    "com.ddtek.opaccessor.h.as {AppTitle=..., ClientID=d2cadmin,
--     DeviceId=UUID, ConnectorLabel=opc_windows, ...}"
--    Extracts: ConnectorLabel, DeviceId, ClientID, DeviceName,
--              ConnectorVersion, DefaultDeployment, LoadBalancer
--
-- 2) DeviceId creation line:
--    "com.ddtek.opaccessor.h.<init> DeviceId is missing ...
--     created new id UUID"
--    Extracts: DeviceId
--
-- The composite connector ID (DeviceId + ClientID) is also derived,
-- matching the format used by the server side in connectorId= fields.
--
-- Sets cluster.name from DefaultDeployment so OPC logs can be
-- filtered by the cluster dashboard variable.
-- ═══════════════════════════════════════════════════════════════
function enrich_opc_accessor(record)
    local msg = record["message"] or record["log"] or ""

    -- ── Config block extraction ──────────────────────────────
    -- Pattern: "{key=value, key=value, ...}" from Java Map.toString()
    if string.find(msg, "ClientID=") then
        record["hdp.log_type"] = "opc-config"

        -- Extract key connector identity fields
        local client_id = string.match(msg, "ClientID=([^,}]+)")
        if client_id then
            record["hdp.opc.client_id"] = client_id:gsub("%s+$", "")
        end

        local connector_label = string.match(msg, "ConnectorLabel=([^,}]+)")
        if connector_label then
            record["hdp.opc.connector_label"] = connector_label:gsub("%s+$", "")
        end

        local device_id = string.match(msg, "DeviceId=([^,}]+)")
        if device_id and device_id ~= "" then
            record["hdp.opc.device_id"] = device_id:gsub("%s+$", "")
        end

        local device_name = string.match(msg, "DeviceName=([^,}]+)")
        if device_name then
            record["hdp.opc.device_name"] = device_name:gsub("%s+$", "")
        end

        local connector_version = string.match(msg, "ConnectorVersion=([^,}]+)")
        if connector_version then
            record["hdp.opc.connector_version"] = connector_version:gsub("%s+$", "")
        end

        local deployment = string.match(msg, "DefaultDeployment=([^,}]+)")
        if deployment then
            deployment = deployment:gsub("%s+$", "")
            record["hdp.opc.deployment"] = deployment
            -- Set hdp.cluster so OPC logs can be filtered by cluster
            if not record["hdp.cluster"] or record["hdp.cluster"] == "" then
                record["hdp.cluster"] = deployment
            end
            -- Cache in cluster_cache so other OPC components
            -- (opc-das, opc-tomcat, etc.) also get hdp.cluster
            -- via resolve_cluster() without needing update.properties.
            local host = record["host.name"]
            if host and deployment ~= "" then
                bset(cluster_cache, cluster_order, host, deployment)
            end
        end

        local load_balancer = string.match(msg, "LoadBalancer=([^,}]+)")
        if load_balancer then
            record["hdp.opc.load_balancer"] = load_balancer:gsub("%s+$", "")
        end

        local install_dir = string.match(msg, "InstallDir=([^,}]+)")
        if install_dir then
            record["hdp.opc.install_dir"] = install_dir:gsub("%s+$", "")
        end

        -- Derive composite connector ID: DeviceId + ClientID
        -- This matches the server-side connectorId format
        -- e.g. "65b1fc33-a0b4-4cf1-98f9-346c265689eed2cadmin"
        if record["hdp.opc.device_id"] and record["hdp.opc.client_id"] then
            record["hdp.opc.connector_id"] = record["hdp.opc.device_id"] .. record["hdp.opc.client_id"]
        end
    end

    -- ── DeviceId creation line ───────────────────────────────
    -- "DeviceId is missing in the OnPremise.properties file,
    --  created new id UUID"
    local new_device_id = string.match(msg, "created new id%s+([%x%-]+)")
    if new_device_id then
        record["hdp.opc.device_id"] = new_device_id
        if not record["hdp.log_type"] then
            record["hdp.log_type"] = "opc-init"
        end
    end
end

-- ═══════════════════════════════════════════════════════════════
-- Enrich server-side DAS logs with OPC connection events.
-- Parses the makeHostConnection pattern from DAS onpremise:
--
--   "datadirect.jdbc.ddcloud.onpremise.common.makeHostConnection
--    ... [connectorId=UUID+user][connector-name=Name]"
--
-- Also detects OPAS listener startup events from onPremiseConnection:
--   "OnPremiseConnection Extended Notification ... opa_<host>_<port>"
--
-- These identify which OPC connectors are actively communicating
-- with the HDP server, visible from the server's perspective.
-- ═══════════════════════════════════════════════════════════════
function enrich_opc_server_side(record)
    local msg = record["message"] or record["log"] or ""

    -- ── makeHostConnection event ─────────────────────────────
    -- Server logs when an OPC connector establishes connection
    if string.find(msg, "makeHostConnection") then
        record["hdp.log_type"] = "opc-connection"

        -- Extract connectorId (DeviceId + ClientID composite)
        -- P3-30: We assume the DeviceId portion is a CANONICAL
        -- 36-char UUID with hyphens (8-4-4-4-12). HDP server emits
        -- it that way; if a future OPC client ever switches to a
        -- compact 32-char UUID (no hyphens) the regex below will
        -- not match and device_id/client_id will be left unset.
        -- Update the pattern here if that happens.
        local connector_id = string.match(msg, "%[connectorId=([^%]]+)%]")
        if connector_id then
            record["hdp.opc.connector_id"] = connector_id

            -- Split composite ID: UUID part (36 chars with hyphens) + user
            -- Pattern: 8-4-4-4-12 hex UUID followed by username
            local device_id, client_id = string.match(connector_id,
                "^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)(.+)$")
            if device_id then
                record["hdp.opc.device_id"] = device_id
                record["hdp.opc.client_id"] = client_id
            end
        end

        -- Extract connector-name
        local connector_name = string.match(msg, "%[connector%-name=([^%]]+)%]")
        if connector_name then
            record["hdp.opc.connector_name"] = connector_name
        end

        -- Extract X-Forwarded-For (OPC IP address)
        local opc_ip = string.match(msg, "X%-Forwarded%-For:%s*([%d%.]+)")
        if opc_ip then
            record["hdp.opc.ip"] = opc_ip
        end

        -- Extract OPAS response code
        local opas_response = string.match(msg, "X%-DataDirect%-OPAS%-Response:(%d+)")
        if opas_response then
            record["hdp.opc.opas_response"] = opas_response
        end

        -- Extract OPAS host ID
        local host_id = string.match(msg, "X%-DataDirect%-OPAS%-HostId:([^<]+)")
        if host_id then
            record["hdp.opc.opas_host_id"] = host_id:gsub("%s+$", "")
        end
    end

    -- ── OPAS listener startup ────────────────────────────────
    -- "OnPremiseConnection Extended Notification 127.0.0.1\n10.30.237.143\nopa_hdp-1_40501"
    if string.find(msg, "OnPremiseConnection Extended Notification") then
        record["hdp.log_type"] = "opc-listener"
        local opa_host = string.match(msg, "opa_([^%s]+)")
        if opa_host then
            record["hdp.opc.opas_host"] = opa_host
        end
    end

    -- ── OPAS socket bound ────────────────────────────────────
    -- "OnPremiseHostListener.run() bound server socket [port=40501][usingSSL=true]"
    if string.find(msg, "bound server socket") then
        record["hdp.log_type"] = "opc-listener"
        local port = string.match(msg, "%[port=(%d+)%]")
        if port then
            record["hdp.opc.opas_port"] = port
        end
        local ssl = string.match(msg, "%[usingSSL=(%w+)%]")
        if ssl then
            record["hdp.opc.opas_ssl"] = ssl
        end
    end
end

-- ═══════════════════════════════════════════════════════════════
-- Enrich deploy.log with deployment phase and success/failure.
-- Detects key deployment milestones and the final outcome.
--
-- Timestamp strategy: Use REAL deployment timestamps so that the
-- Grafana time picker correctly shows only hosts deployed within
-- the selected range.
--
-- ALL parsing done in Lua (no regex parser filter):
--   - Extract Java US-locale timestamp from raw log text
--   - Extract source class, level, and message from multiline records
--   - Cache latest deploy timestamp per host for error/final/props
--
-- Loki handles out-of-order writes via unordered_writes: true and
-- time-based stream sharding.
-- ═══════════════════════════════════════════════════════════════
function enrich_deploy_log(record, hostname, rec_ts)
    local raw = record["log"] or ""
    local now = os.time()

    record["hdp.log_type"] = "deploy"

    -- ── Line-by-line parsing (no multiline parser) ────────────
    -- deploy.log has three line types:
    --   A) Java timestamp + source:  "Jun 04, 2025 7:26:59 AM hdpCloudSchema"
    --   B) Java level + message:     "INFO: Does object exist[count=1]"
    --   C) Shell commands / plain:   "cp -v file1 file2"
    --
    -- For (A): extract timestamp + source, cache timestamp per host
    -- For (B): extract level + message, use cached timestamp
    -- For (C): use cached/ingestion timestamp, line IS the message

    local lua_ts = parse_java_us_timestamp(raw)

    if lua_ts then
        -- ── Type A: Java timestamp line ──────────────────────
        -- Extract source class: text after AM/PM
        local src = string.match(raw, "[AP]M%s+(%S+)")
        if src then
            record["source"] = src
            record["message"] = src  -- class name as message for this line
        end
        -- Cache this timestamp for subsequent lines from same host
        bset(deploy_ts_cache, deploy_ts_order, hostname, lua_ts)
    else
        -- Check for level prefix (Type B) or plain text (Type C)
        local lvl, msg_text = string.match(raw, "^(%u+):%s*(.*)")
        if lvl and severity_map[lvl] then
            -- ── Type B: Level + message line ─────────────────
            record["level"] = lvl
            record["message"] = msg_text or ""
            record["severity_number"] = severity_map[lvl]
            -- Inherit source from previous cached info
        end
        -- Type C lines keep raw text as message (set by caller)
    end

    -- Use record's message for phase detection
    local msg = record["message"] or raw

    -- ── Determine record timestamp ────────────────────────────
    -- 1. Real Lua-extracted timestamp (Java timestamp lines)
    -- 2. Cached deploy timestamp (level lines, shell commands)
    -- 3. Ingestion time (fallback)
    -- NOTE: Return plain numbers (epoch seconds), NOT tables.
    -- Fluent Bit's Lua filter ignores {sec=,nsec=} table timestamps.
    local ret_ts = nil
    local ts_source = "unknown"

    if lua_ts then
        -- Extracted a real deployment timestamp (old or recent)
        ret_ts = lua_ts
        bset(deploy_ts_cache, deploy_ts_order, hostname, lua_ts)
        ts_source = "parsed"
    else
        -- No extractable timestamp (shell commands, plain text lines)
        if deploy_ts_cache[hostname] then
            ret_ts = deploy_ts_cache[hostname]
            ts_source = "cached"
        else
            ret_ts = now
            ts_source = "ingestion"
        end
    end

    -- Store the deployment timestamp as an attribute for dashboard use
    if deploy_ts_cache[hostname] then
        record["hdp.deploy.timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ", deploy_ts_cache[hostname])
    end

    -- Detect deployment outcome
    if string.find(msg, "Hybrid Data Pipeline deployment complete") then
        record["hdp.deploy.status"] = "SUCCESS"
        record["hdp.deploy.phase"]  = "complete"
    elseif string.find(msg, "ERROR") or string.find(msg, "SEVERE") or string.find(msg, "FATAL") then
        record["hdp.deploy.status"] = "ERROR"
    end

    -- Classify deployment phase from key markers
    if not record["hdp.deploy.phase"] then
        if string.find(msg, "Installing Bouncy Castle") then
            record["hdp.deploy.phase"] = "crypto-setup"
        elseif string.find(msg, "Copying shared keystore") then
            record["hdp.deploy.phase"] = "keystore-setup"
        elseif string.find(msg, "Setting up SSL") then
            record["hdp.deploy.phase"] = "ssl-setup"
        elseif string.find(msg, "Setting up DB connection") or string.find(msg, "Setting up database") then
            record["hdp.deploy.phase"] = "database-setup"
        elseif string.find(msg, "Creating database schema") then
            record["hdp.deploy.phase"] = "schema-creation"
        elseif string.find(msg, "Copying WebUI") then
            record["hdp.deploy.phase"] = "webui-setup"
        elseif string.find(msg, "Copying non%-driver datastores") or string.find(msg, "Copying datastores") then
            record["hdp.deploy.phase"] = "datastore-setup"
        elseif string.find(msg, "Starting DAS") then
            record["hdp.deploy.phase"] = "das-start"
        elseif string.find(msg, "Tomcat started") then
            record["hdp.deploy.phase"] = "tomcat-started"
        elseif string.find(msg, "Starting Notification") then
            record["hdp.deploy.phase"] = "notification-start"
        elseif string.find(msg, "Notification server process started") then
            record["hdp.deploy.phase"] = "notification-started"
        elseif string.find(msg, "Removing lock file") then
            record["hdp.deploy.phase"] = "cleanup"
        end
    end

    -- Extract JVM heap settings from CATALINA_OPTS / JAVA_OPTS
    local xmx = string.match(msg, "%-Xmx(%d+)m")
    if xmx then
        record["hdp.jvm.heap_max_mb"] = xmx
    end
    local xms = string.match(msg, "%-Xms(%d+)m")
    if xms then
        record["hdp.jvm.heap_init_mb"] = xms
    end

    -- Return the determined timestamp
    return ret_ts
end

-- ═══════════════════════════════════════════════════════════════
-- Enrich error.log with certificate import results and real errors.
-- error.log is stdout/stderr from keytool and shell commands.
-- Uses the cached deploy timestamp from the same host.
-- ═══════════════════════════════════════════════════════════════
function enrich_error_log(record, hostname, rec_ts)
    local msg = record["message"] or record["log"] or ""
    local now = os.time()

    record["hdp.log_type"] = "error"
    -- P1-12: per-host counter so concurrent hosts do not collide.
    local n = bump(error_line_counter, error_line_order, hostname)

    -- Store the cached deploy timestamp as an attribute
    if deploy_ts_cache[hostname] then
        record["hdp.deploy.timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ", deploy_ts_cache[hostname])
    end

    -- Detect certificate import summary line
    -- "Import command completed:  148 entries successfully imported, 0 entries failed or cancelled"
    local imported, failed = string.match(msg, "Import command completed:%s+(%d+) entries successfully imported,%s+(%d+) entries failed")
    if imported then
        record["hdp.cert.imported"] = imported
        record["hdp.cert.failed"]   = failed
        record["hdp.deploy.phase"]  = "cert-import-summary"
        if tonumber(failed) > 0 then
            record["hdp.deploy.status"] = "WARNING"
        else
            record["hdp.deploy.status"] = "OK"
        end
    end

    -- Detect real errors (not cert warnings)
    if string.find(msg, "^Error") or string.find(msg, "cannot access") or string.find(msg, "No such file") then
        record["hdp.deploy.status"] = "WARNING"
        record["hdp.deploy.phase"]  = "error"
    end

    -- Use cached deploy timestamp for error records.
    -- Add fractional offset (n * 0.001) for uniqueness.
    -- P1-12: counter is per-host so two hosts do not collide.
    -- NOTE: Return plain number, NOT table — FB Lua ignores {sec,nsec} tables.
    if deploy_ts_cache[hostname] then
        return deploy_ts_cache[hostname] + n * 0.001
    end
    return now
end

-- ═══════════════════════════════════════════════════════════════
-- Enrich final.log — single-line deployment completion marker.
-- Uses the cached deploy timestamp from the same host so that
-- the deployment status panel respects the Grafana time picker.
-- ═══════════════════════════════════════════════════════════════
function enrich_final_log(record, hostname)
    local msg = record["message"] or record["log"] or ""

    record["hdp.log_type"] = "final"
    -- P1-12: per-host counter (kept for symmetry; final.log is
    -- single-line so the offset rarely matters in practice).
    bump(final_line_counter, final_line_order, hostname)

    -- Store the cached deploy timestamp as an attribute
    if deploy_ts_cache[hostname] then
        record["hdp.deploy.timestamp"] = os.date("!%Y-%m-%dT%H:%M:%SZ", deploy_ts_cache[hostname])
    end

    -- Detect deployment outcome
    if string.find(msg, "Hybrid Data Pipeline deployment complete") then
        record["hdp.deploy.status"] = "SUCCESS"
        record["hdp.deploy.phase"]  = "complete"
    end

    -- Use cached deploy timestamp for final record.
    -- NOTE: Return plain number, NOT table — FB Lua ignores {sec,nsec} tables.
    if deploy_ts_cache[hostname] then
        return deploy_ts_cache[hostname] + 0.999
    end
    return os.time()
end

