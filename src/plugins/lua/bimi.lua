--[[
Copyright (c) 2022, Vsevolod Stakhov <vsevolod@rspamd.com>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local N = "bimi"
local lua_util = require "lua_util"
local rspamd_logger = require "rspamd_logger"
local ts = (require "tableshape").types
local lua_redis = require "lua_redis"
local ucl = require "ucl"
local lua_mime = require "lua_mime"
local rspamd_http = require "rspamd_http"
local rspamd_util = require "rspamd_util"

local settings = {
  helper_url = "http://127.0.0.1:3030",
  helper_timeout = 5,
  helper_sync = true,
  vmc_only = true,
  redis_prefix = 'rs_bimi',
  redis_min_expiry = 24 * 3600,
}
local redis_params

local settings_schema = lua_redis.enrich_schema({
  helper_url = ts.string,
  helper_timeout = ts.number + ts.string / lua_util.parse_time_interval,
  helper_sync = ts.boolean,
  vmc_only = ts.boolean,
  redis_min_expiry = ts.number + ts.string / lua_util.parse_time_interval,
  redis_prefix = ts.string,
  enabled = ts.boolean:is_optional(),
})

local function check_dmarc_policy(task)
  local dmarc_sym = task:get_symbol('DMARC_POLICY_ALLOW')

  if not dmarc_sym then
    lua_util.debugm(N, task, "no DMARC allow symbol")
    return nil
  end

  local opts = dmarc_sym[1].options or {}
  if not opts[1] or #opts ~= 2 then
    lua_util.debugm(N, task, "DMARC options are bogus: %s", opts)
    return nil
  end

  -- opts[1] - domain; opts[2] - policy
  local dom, policy = opts[1], opts[2]

  if policy ~= 'reject' and policy ~= 'quarantine' then
    lua_util.debugm(N, task, "DMARC policy for domain %s is not strict: %s",
        dom, policy)
    return nil
  end

  return dom
end

local function gen_bimi_grammar()
  local lpeg = require "lpeg"
  lpeg.locale(lpeg)
  local space = lpeg.space ^ 0
  local name = lpeg.C(lpeg.alpha ^ 1) * space
  local sep = (lpeg.S("\\;") * space) + (lpeg.space ^ 1)
  local value = lpeg.C(lpeg.P(lpeg.graph - sep) ^ 1)
  local pair = lpeg.Cg(name * "=" * space * value) * sep ^ -1
  local list = lpeg.Cf(lpeg.Ct("") * pair ^ 0, rawset)
  local version = lpeg.P("v") * space * lpeg.P("=") * space * lpeg.P("BIMI1")
  local record = version * sep * list

  return record
end

local bimi_grammar = gen_bimi_grammar()

local function check_bimi_record(task, rec)
  local elts = bimi_grammar:match(rec)

  if elts then
    lua_util.debugm(N, task, "got BIMI record: %s, processed=%s",
        rec, elts)
    local res = {}

    if type(elts.l) == 'string' then
      res.l = elts.l
    end
    if type(elts.a) == 'string' then
      res.a = elts.a
    end

    if res.l or res.a then
      return res
    end
  end
end

local function insert_bimi_headers(task, domain, bimi_content)
  local hdr_name = 'BIMI-Indicator'
  -- Re-encode base64...
  local content = rspamd_util.encode_base64(rspamd_util.decode_base64(bimi_content),
      73, task:get_newlines_type())
  lua_mime.modify_headers(task, {
    remove = { [hdr_name] = 0 },
    add = {
      [hdr_name] = {
        order = 0,
        value = rspamd_util.fold_header(hdr_name, content,
            task:get_newlines_type())
      }
    }
  })
  task:insert_result('BIMI_VALID', 1.0, { domain })
end

local function process_bimi_json(task, domain, redis_data)
  local parser = ucl.parser()
  local _, err = parser:parse_string(redis_data)

  if err then
    rspamd_logger.errx(task, "cannot parse BIMI result from Redis for %s: %s",
        domain, err)
  else
    local d = parser:get_object()
    if d.content then
      insert_bimi_headers(task, domain, d.content)
    elseif d.error then
      lua_util.debugm(N, task, "invalid BIMI for %s: %s",
          domain, d.error)
    end
  end
end

local function make_helper_request(task, domain, record, redis_server)
  local is_sync = settings.helper_sync
  local helper_url = string.format('%s/v1/check', settings.helper_url)
  local redis_key = string.format('%s%s', settings.redis_prefix,
      domain)

  local function http_helper_callback(http_err, code, body, _)
    if http_err then
      rspamd_logger.warnx(task, 'got error reply from helper %s: code=%s; reply=%s',
          helper_url, code, http_err)
      return
    end
    if code ~= 200 then
      rspamd_logger.warnx(task, 'got non 200 reply from helper %s: code=%s; reply=%s',
          helper_url, code, http_err)
      return
    end
    if is_sync then
      local parser = ucl.parser()
      local _, err = parser:parse_string(body)

      if err then
        rspamd_logger.errx(task, "cannot parse BIMI result from helper for %s: %s",
            domain, err)
      else
        local d = parser:get_object()
        if d.content then
          insert_bimi_headers(task, domain, d.content)
        elseif d.error then
          lua_util.debugm(N, task, "invalid BIMI for %s: %s",
              domain, d.error)
        end

        local ret, upstream
        local function redis_set_cb(redis_err, _)
          if redis_err then
            rspamd_logger.warnx(task, 'cannot get reply from Redis when storing image %s: %s',
                upstream:get_addr():to_string(), redis_err)
            upstream:fail()
          else
            lua_util.debugm(N, task, 'stored bimi image in Redis for domain %s; key=%s',
                domain, redis_key)
          end
        end

        ret, _, upstream = lua_redis.redis_make_request(task,
            redis_params, -- connect params
            redis_key, -- hash key
            true, -- is write
            redis_set_cb, --callback
            'PSETEX', -- command
            { redis_key, tostring(settings.redis_min_expiry * 1000.0),
              ucl.to_format(d, "json-compact") })

        if not ret then
          rspamd_logger.warnx(task, 'cannot make request to Redis when storing image; domain %s',
              domain)
        end
      end
    else
      -- In async mode we skip request and use merely Redis to insert indicators
      lua_util.debugm(N, task, "sent request to resolve %s to %s",
          domain, helper_url)
    end
  end

  local request_data = {
    url = record.a,
    sync = is_sync,
    domain = domain
  }

  if not is_sync then
    -- Allow bimi helper to save data in Redis
    request_data.redis_server = redis_server
    request_data.redis_prefix = settings.redis_prefix
    request_data.redis_expiry = settings.redis_min_expiry * 1000.0
  else
    request_data.skip_redis = true
  end

  local serialised = ucl.to_format(request_data, 'json-compact')
  lua_util.debugm(N, task, "send request to BIMI helper: %s",
      serialised)
  rspamd_http.request({
    task = task,
    mime_type = 'application/json',
    timeout = settings.helper_timeout,
    body = serialised,
    url = helper_url,
    callback = http_helper_callback,
    keepalive = true,
  })
end

local function check_bimi_vmc(task, domain, record)
  local redis_key = string.format('%s%s', settings.redis_prefix,
      domain)
  local ret, _, upstream

  local function redis_cached_cb(err, data)
    if err then
      rspamd_logger.warnx(task, 'cannot get reply from Redis %s: %s',
          upstream:get_addr():to_string(), err)
      upstream:fail()
    else
      if type(data) == 'string' then
        -- We got a cached record, good stuff
        lua_util.debugm(N, task, "got valid cached BIMI result for domain: %s",
            domain)
        process_bimi_json(task, domain, data)
      else
        -- Get server addr + port
        -- We need to fix IPv6 address as redis-rs has no support of
        -- the braced IPv6 addresses
        local db, password = '', ''
        if redis_params.db then
          db = string.format('/%s', redis_params.db)
        end
        if redis_params.username then
          if redis_params.password then
            password = string.format('%s:%s@', redis_params.username, redis_params.password)
          else
            rspamd_logger.warnx(task, "Redis requires a password when username is supplied")
          end
        elseif redis_params.password then
          password = string.format(':%s@', redis_params.password)
        end
        local redis_server = string.format('redis://%s%s:%s%s',
            password,
            upstream:get_name(), upstream:get_port(),
            db)
        make_helper_request(task, domain, record, redis_server)
      end
    end
  end

  -- We first check Redis and then try to use helper
  ret, _, upstream = lua_redis.redis_make_request(task,
      redis_params, -- connect params
      redis_key, -- hash key
      false, -- is write
      redis_cached_cb, --callback
      'GET', -- command
      { redis_key })

  if not ret then
    rspamd_logger.warnx(task, 'cannot make request to Redis; domain %s', domain)
  end
end

local function check_bimi_dns(task, domain)
  local resolve_name = string.format('default._bimi.%s', domain)
  local dns_cb = function(_, _, results, err)
    if err then
      lua_util.debugm(N, task, "cannot resolve bimi for %s: %s",
          domain, err)
    else
      for _, rec in ipairs(results) do
        local res = check_bimi_record(task, rec)

        if res then
          if settings.vmc_only and not res.a then
            lua_util.debugm(N, task, "BIMI for domain %s has no VMC, skip it",
                domain)

            return
          end

          if res.a then
            check_bimi_vmc(task, domain, res)
          elseif res.l then
            -- TODO: add l check
            lua_util.debugm(N, task, "l only BIMI for domain %s is not implemented yet",
                domain)
          end
        end
      end
    end
  end
  task:get_resolver():resolve_txt({
    task = task,
    name = resolve_name,
    callback = dns_cb,
    forced = true
  })
end

local function bimi_callback(task)
  local dmarc_domain_maybe = check_dmarc_policy(task)

  if not dmarc_domain_maybe then
    return
  end


  -- We can either check BIMI via DNS or check Redis cache
  -- BIMI check is an external check, so we might prefer Redis to be checked
  -- first. On the other hand, DNS request is cheaper and counting low BIMI
  -- adaptation we would need to have both Redis and DNS request to hit no
  -- result. So, it might be better to check DNS first at this stage...
  check_bimi_dns(task, dmarc_domain_maybe)
end

local opts = rspamd_config:get_all_opt('bimi')
if not opts then
  lua_util.disable_module(N, "config")
  return
end

settings = lua_util.override_defaults(settings, opts)
local res, err = settings_schema:transform(settings)

if not res then
  rspamd_logger.warnx(rspamd_config, 'plugin %s is misconfigured: %s', N, err)
  local err_msg = string.format("schema error: %s", res)
  lua_util.config_utils.push_config_error(N, err_msg)
  lua_util.disable_module(N, "failed", err_msg)
  return
end

rspamd_logger.infox(rspamd_config, 'enabled BIMI plugin')

settings = res
redis_params = lua_redis.parse_redis_server(N, opts)

if redis_params then
  local id = rspamd_config:register_symbol({
    name = 'BIMI_CHECK',
    type = 'normal',
    callback = bimi_callback,
    augmentations = { string.format("timeout=%f", settings.helper_timeout or
        redis_params.timeout or 0.0) }
  })
  rspamd_config:register_symbol {
    name = 'BIMI_VALID',
    type = 'virtual',
    parent = id,
    score = 0.0
  }

  rspamd_config:register_dependency('BIMI_CHECK', 'DMARC_CHECK')
else
  lua_util.disable_module(N, "redis")
end
