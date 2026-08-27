import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { LuaEngine } from 'wasmoon';

const root = process.cwd();

export async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

export async function bootstrapControlLua(engine: LuaEngine): Promise<void> {
  const [limits, sanitizer, protocol] = await Promise.all([
    source('resources/synex_control/shared/limits.lua'),
    source('resources/synex_control/server/sanitizer.lua'),
    source('resources/synex_control/server/request_protocol.lua'),
  ]);
  await engine.doString(`
    local function encodeString(value)
      return string.format('%q', value)
    end
    local function encodeValue(value, seen)
      local kind = type(value)
      if kind == 'nil' then return 'null' end
      if kind == 'boolean' or kind == 'number' then return tostring(value) end
      if kind == 'string' then return encodeString(value) end
      if kind ~= 'table' then error('unsupported JSON value') end
      if seen[value] then error('cycle') end
      seen[value] = true
      local array, count, maximum = true, 0, 0
      for key in pairs(value) do
        count = count + 1
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then array = false end
        if type(key) == 'number' then maximum = math.max(maximum, key) end
      end
      if array and maximum ~= count then array = false end
      local parts = {}
      if array then
        for index = 1, count do parts[#parts + 1] = encodeValue(value[index], seen) end
        seen[value] = nil
        return '[' .. table.concat(parts, ',') .. ']'
      end
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = tostring(key) end
      table.sort(keys)
      for _, key in ipairs(keys) do
        parts[#parts + 1] = encodeString(key) .. ':' .. encodeValue(value[key], seen)
      end
      seen[value] = nil
      return '{' .. table.concat(parts, ',') .. '}'
    end
    json = { encode = function(value) return encodeValue(value, {}) end }
    assert(load(${JSON.stringify(limits)}, '@resources/synex_control/shared/limits.lua'))()
    assert(load(${JSON.stringify(sanitizer)}, '@resources/synex_control/server/sanitizer.lua'))()
    assert(load(${JSON.stringify(protocol)}, '@resources/synex_control/server/request_protocol.lua'))()
  `);
}
