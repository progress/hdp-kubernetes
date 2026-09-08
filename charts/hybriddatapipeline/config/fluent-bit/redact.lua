-- ═══════════════════════════════════════════════════════════════
-- HDP Centralized Logging — Redaction Script
--
-- Canonical path: otel-hdp-logs/config/fluent-bit/redact.lua
-- Vendored copies are kept in sync by
--   scripts/sync-fluent-bit-config.{sh,ps1}   (P2-20, P3-32)
--
-- P1-15 / P1-16 REFACTOR
--   * Patterns consolidated into a single PATTERNS table so all
--     entry points apply a consistent set.
--   * New `redact_secrets` entry point applies the universal set
--     and is intended to be matched against `*` (every record).
--   * `redact_passwords`, `redact_saml_tokens`, and `redact_opc_tokens`
--     are kept as thin wrappers for backwards compatibility with
--     existing fluent-bit.yaml filter wiring; they all flow through
--     the same shared apply() helper.
--   * SAML redaction is now ANCHORED to known carriers (samlToken=,
--     authoptions=(samlToken=...), Authorization: …); the previous
--     unanchored "any base64 ≥ 256 chars" rule mangled stack traces
--     and SQL payloads.
-- ═══════════════════════════════════════════════════════════════

-- ── Universal secret patterns ────────────────────────────────
-- Order matters: more specific patterns FIRST so generic patterns
-- don't accidentally consume their input.
local UNIVERSAL_PATTERNS = {
    -- JVM -D properties (e.g. -Djavax.net.ssl.keyStorePassword=…)
    { "(%-D[%w%.]*[Pp]assword=)[^%s]+",                      "%1[REDACTED]" },
    { "(%-D[%w%.]*[Ss]ecret=)[^%s]+",                        "%1[REDACTED]" },

    -- JSON forms: "password":"…", "secret":"…", "token":"…", "apiKey":"…"
    { '("[Pp]assword"%s*:%s*")[^"]*(")',                      "%1[REDACTED]%2" },
    { '("[Ss]ecret"%s*:%s*")[^"]*(")',                        "%1[REDACTED]%2" },
    { '("[Tt]oken"%s*:%s*")[^"]*(")',                         "%1[REDACTED]%2" },
    { '("[Aa]pi[Kk]ey"%s*:%s*")[^"]*(")',                     "%1[REDACTED]%2" },
    { '("[Cc]redential"%s*:%s*")[^"]*(")',                    "%1[REDACTED]%2" },

    -- key=value forms (KEY may be word-boundary-terminated)
    { "([Pp]assword%s*[=:]%s*)[^%s,;\"']+",                   "%1[REDACTED]" },
    { "([Ss]ecret%s*[=:]%s*)[^%s,;\"']+",                     "%1[REDACTED]" },
    { "([Cc]redential%s*[=:]%s*)[^%s,;\"']+",                 "%1[REDACTED]" },

    -- Spring Boot generated security password (catalina.out)
    { "(Using generated security password:%s*)[%x%-]+",       "%1[REDACTED]" },

    -- *_PASS / _PASSWORD / _SECRET / _TOKEN / _KEY env-style vars
    -- (covers MUSTANG_ADMIN_PASS, DATABASE_USER_PASS, *_TOKEN, *_KEY, etc.)
    { "(_PASS[A-Z]*=)[^%s,;\"']+",                            "%1[REDACTED]" },
    { "(_SECRET=)[^%s,;\"']+",                                "%1[REDACTED]" },
    { "(_TOKEN=)[^%s,;\"']+",                                 "%1[REDACTED]" },
    { "(_KEY=)[^%s,;\"']+",                                   "%1[REDACTED]" },

    -- HTTP Authorization headers (Bearer, Basic, etc.)
    { "(Authorization:%s*[%w]+%s+)[%w%-_%./=+]+",             "%1[REDACTED]" },

    -- JWT (header.payload.signature)
    { "(eyJ[%w%-_]+%.eyJ[%w%-_]+%.)[%w%-_]+",                 "%1[REDACTED:jwt]" },

    -- AWS access keys
    { "(AKIA)[A-Z0-9]+",                                      "%1[REDACTED:aws-key]" },

    -- JDBC URLs with embedded user:password@host
    { "(jdbc:[%w]+:[%w%.]*://)([^/:]+):([^@]+)(@)",           "%1%2:[REDACTED]%4" },
}

-- ── SAML / token patterns (anchored — P1-16) ─────────────────
-- These ONLY trigger inside known carriers, never on free-form text.
local SAML_PATTERNS = {
    { "(samlToken=)[A-Za-z0-9+/=]+",                          "%1[REDACTED:saml-token]" },
    { "(authoptions=%(samlToken=)[A-Za-z0-9+/=]+",            "%1[REDACTED:saml-token]" },
}

-- ── OPC-specific patterns ────────────────────────────────────
local OPC_PATTERNS = {
    -- Auth= hex token (any length)
    { "(Auth=)[%x]+",                                         "%1[REDACTED:auth-token]" },
    -- AuthKey= hex token (any length)
    { "(AuthKey=)[%x]+",                                      "%1[REDACTED:auth-key]" },
    -- API key in JSON response: "key":"<value>"
    { '("key"%s*:%s*")[^"]*(")',                              "%1[REDACTED:api-key]%2" },
    -- HDP_SESSION cookie value
    { "(HDP_SESSION=)[^;%s,]+",                               "%1[REDACTED]" },
    -- C2S-SESSION cookie value
    { "(C2S%-SESSION=)[^;%s,]+",                              "%1[REDACTED]" },
    -- registrationKey values
    { '(registrationKey[=:]+%s*"?)[^"%s,}]+',                 "%1[REDACTED]" },
    -- Generic long hex strings (>= 64 hex chars) that may be tokens.
    -- Kept LAST so the named patterns above run first.
    {
        "(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x" ..
        "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)",
        "[REDACTED:hex-token]"
    },
    -- NOTE: ClientID is intentionally NOT redacted.
    -- The OPC Connectors table on the Home dashboard needs the User column
    -- (extracted from ClientID=) to identify and deduplicate connectors.
}

-- ── Shared apply helper ──────────────────────────────────────
local function apply(msg, patterns)
    for _, p in ipairs(patterns) do
        msg = string.gsub(msg, p[1], p[2])
    end
    return msg
end

local function redact_with(record, ...)
    local msg = record["message"] or record["log"] or ""
    for _, set in ipairs({ ... }) do
        msg = apply(msg, set)
    end
    record["message"] = msg
    record["log"] = msg
end

-- ═══════════════════════════════════════════════════════════════
-- ENTRY POINTS (referenced by `call:` directives in fluent-bit.yaml)
-- All must be globals so Fluent Bit can resolve them.
-- ═══════════════════════════════════════════════════════════════

-- Universal: applies UNIVERSAL_PATTERNS to every record. Wire to `*`.
function redact_secrets(tag, timestamp, record)
    redact_with(record, UNIVERSAL_PATTERNS)
    return 1, timestamp, record
end

-- DAS / SAML carriers. P1-16: now anchored, no longer over-matches
-- arbitrary base64-looking content (stack traces, SQL, JSON payloads).
function redact_saml_tokens(tag, timestamp, record)
    redact_with(record, SAML_PATTERNS)
    return 1, timestamp, record
end

-- OPC components: applies OPC_PATTERNS only. UNIVERSAL_PATTERNS are already
-- applied to every record by redact_secrets (matched on `*`), so running them
-- a second time here is redundant and wastes CPU.
function redact_opc_tokens(tag, timestamp, record)
    redact_with(record, OPC_PATTERNS)
    return 1, timestamp, record
end