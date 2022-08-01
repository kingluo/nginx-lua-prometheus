local ngx_re_match = ngx.re.match
local select = select
local error = error

local function table_insert_tail(tab, ...)
    local idx = #tab
    for i = 1, select('#', ...) do
        idx = idx + 1
        tab[idx] = select(i, ...)
    end

    return idx
end

local function fix_histogram_bucket_labels(key)
  local match, err = ngx_re_match(key, METRICS_KEY_REGEX, "jo")
  if err then
    error("failed to match regex: " .. err)
    return
  end

  if not match then
    return key
  end

  if match[2] == "Inf" then
    return table.concat({match[1], "+Inf", match[3]})
  else
    return table.concat({match[1], tostring(tonumber(match[2])), match[3]})
  end
end

local function short_metric_name(full_name)
  local labels_start, _ = full_name:find("{")
  if not labels_start then
    return full_name
  end
  -- Try to detect if this is a histogram metric. We only check for the
  -- `_bucket` suffix here, since it alphabetically goes before other
  -- histogram suffixes (`_count` and `_sum`).
  local suffix_idx, _ = full_name:find("_bucket{")
  if suffix_idx and full_name:find("le=") then
    -- this is a histogram metric
    return full_name:sub(1, suffix_idx - 1)
  end
  -- this is not a histogram metric
  return full_name:sub(1, labels_start - 1)
end

local function shdict_metric_data(dict_name, keys, registry, prefix)
  local dict = ngx.shared[dict_name]
  local err_keys = {}

  -- Prometheus server expects buckets of a histogram to appear in increasing
  -- numerical order of their label values.
  table.sort(keys)

  local seen_metrics = {}
  local output = {}
  for _, key in ipairs(keys) do
    local value, err = dict:get(key)
    if value then
      local short_name = short_metric_name(key)
      if not seen_metrics[short_name] then
        local m = registry[short_name]
        if m then
          if m.help then
            table_insert_tail(output, string.format("# HELP %s%s %s\n",
            prefix, short_name, m.help))
          end
          if m.typ then
            table_insert_tail(output, string.format("# TYPE %s%s %s\n",
              prefix, short_name, TYPE_LITERAL[m.typ]))
          end
        end
        seen_metrics[short_name] = true
      end
      key = fix_histogram_bucket_labels(key)
      table_insert_tail(output, string.format("%s%s %s\n", prefix, key, value))
    else
      if type(err) == "string" then
        err_keys[key] = err
      end
    end
  end

  return output, err_keys
end

return {shdict_metric_data = shdict_metric_data}
