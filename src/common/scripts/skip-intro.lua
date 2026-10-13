-- skip-intro.lua
-- Persistent auto-skip intro/outro script
-- Key: local files use their directory, network videos use the full URL
-- Compatible with Windows / macOS / Linux
-- _ script-message-to skip_intro set-mark start       #menu: 标记 > 设置当前片头
-- _ script-message-to skip_intro set-mark end         #menu: 标记 > 设置当前片尾
-- _ script-message-to skip_intro clear-marks          #menu: 标记 > 清空当前标记
-- _ script-message-to skip_intro clear-all-marks      #menu: 标记 > 清空所有标记
-- _ script-message-to skip_intro goto-mark start      #menu: 标记 > 跳到片头
-- _ script-message-to skip_intro goto-mark end        #menu: 标记 > 跳到片尾
-- _ script-message-to skip_intro show-marks           #menu: 标记 > 显示标记
-- _ script-message-to skip_intro toggle-auto-start    #menu: 标记 > 自动跳过片头 #@state=(ud_skip_intro_auto_skip_start and 'checked')
-- _ script-message-to skip_intro toggle-auto-end      #menu: 标记 > 自动跳过片尾 #@state=(ud_skip_intro_auto_skip_end and 'checked')

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local MARK_FILE = mp.command_native({'expand-path', '~~/script-opts/skip-intro.json'})

-- State
local marks = {}
local current_key = nil
local auto_skip_start = false
local auto_skip_end = false

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function get_time_pos()
    return mp.get_property_number('time-pos')
end

local function fmt(t)
    if not t then return 'unset' end
    return string.format('%.3f', t)
end

local function is_url(path)
    if not path then return false end
    return path:match('^%a[%w+.-]*://') ~= nil
end

local function key_for(path)
    if not path or path == '' then return nil end

    if is_url(path) then
        -- Strip query string (everything after ?)
        path = path:gsub('%?.*$', '')
        return path
    end

    path = path:gsub('^file://', '')
    local dir = path:match('^(.*)[/\\][^/\\]+$')
    if dir and dir ~= '' then
        dir = dir:gsub('\\', '/')
        return dir
    end
    return path
end

local function ensure_marks(key)
    if not key then return nil end
    if not marks[key] then
        marks[key] = {}
    end
    return marks[key]
end

------------------------------------------------------------
-- Sync state to mpv properties (so #@state= can read them)
------------------------------------------------------------

local function sync_state_to_mpv()
    mp.set_property_native('user-data/skip-intro-auto-skip-start', auto_skip_start)
    mp.set_property_native('user-data/skip-intro-auto-skip-end', auto_skip_end)
end

------------------------------------------------------------
-- Directory creation
------------------------------------------------------------

local function ensure_dir_for(file_path)
    local dir = file_path:match('^(.*)[/\\][^/\\]+$')
    if not dir or dir == '' then return true end

    local info = utils.file_info(dir)
    if info and info.is_dir then return true end

    msg.info('skip-intro: creating directory ' .. dir)

    local sep = package.config:sub(1, 1)
    local ok
    if sep == '\\' then
        ok = utils.subprocess({
            args = {'cmd', '/C', 'mkdir', '"' .. dir .. '"'},
            cancellable = false,
        })
    else
        ok = utils.subprocess({
            args = {'mkdir', '-p', dir},
            cancellable = false,
        })
    end

    if not ok or ok.status ~= 0 then
        msg.error('skip-intro: failed to create directory ' .. dir)
        return false
    end
    return true
end

------------------------------------------------------------
-- JSON helpers (hand-written, avoids format_json quirks)
------------------------------------------------------------

local function json_escape(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

local function build_marks_json()
    local parts = {}
    for k, v in pairs(marks) do
        local inner = {}
        if type(v.start) == 'number' then
            inner[#inner + 1] = string.format('"start":%.3f', v.start)
        end
        if type(v["end"]) == 'number' then
            inner[#inner + 1] = string.format('"end":%.3f', v["end"])
        end
        parts[#parts + 1] = string.format('"%s":{%s}', json_escape(k), table.concat(inner, ','))
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

------------------------------------------------------------
-- Persistence
------------------------------------------------------------

local function load_marks()
    local f = io.open(MARK_FILE, 'r')
    if not f then
        msg.info('skip-intro: no mark file yet at ' .. MARK_FILE)
        marks = {}
        return
    end
    local content = f:read('*a')
    f:close()

    if not content or content == '' then
        marks = {}
        return
    end

    local ok, data = pcall(utils.parse_json, content)
    if not ok or type(data) ~= 'table' then
        msg.warn('skip-intro: failed to parse ' .. MARK_FILE)
        marks = {}
        return
    end

    if data.marks and type(data.marks) == 'table' then
        marks = data.marks
        if type(data.auto_skip_start) == 'boolean' then
            auto_skip_start = data.auto_skip_start
        end
        if type(data.auto_skip_end) == 'boolean' then
            auto_skip_end = data.auto_skip_end
        end
    else
        marks = data
    end

    local n = 0
    for _ in pairs(marks) do n = n + 1 end
    msg.info(string.format('skip-intro: loaded %d key(s), auto_start=%s, auto_end=%s',
        n, tostring(auto_skip_start), tostring(auto_skip_end)))
end

local function save_marks()
    -- 打印当前 marks 内容，方便确认
    local mark_count = 0
    for k, v in pairs(marks) do
        mark_count = mark_count + 1
        local s = v.start and string.format('%.3f', v.start) or 'nil'
        local e = v["end"] and string.format('%.3f', v["end"]) or 'nil'
        msg.info(string.format('skip-intro: save_marks: key=%s start=%s end=%s', k, s, e))
    end
    msg.info(string.format('skip-intro: save_marks: %d key(s), auto_start=%s, auto_end=%s',
        mark_count, tostring(auto_skip_start), tostring(auto_skip_end)))

    -- 手写 JSON
    local marks_json = build_marks_json()
    local auto_start_json = auto_skip_start and 'true' or 'false'
    local auto_end_json = auto_skip_end and 'true' or 'false'
    local json = string.format(
        '{"marks":%s,"auto_skip_start":%s,"auto_skip_end":%s}',
        marks_json, auto_start_json, auto_end_json
    )

    msg.info('skip-intro: save_marks: json = ' .. json)

    if not ensure_dir_for(MARK_FILE) then
        msg.error('skip-intro: save_marks: ensure_dir_for failed')
        return
    end

    local f, err = io.open(MARK_FILE, 'w')
    if not f then
        msg.error('skip-intro: save_marks: cannot open ' .. MARK_FILE .. ' (' .. tostring(err) .. ')')
        return
    end

    local write_ok, write_err = f:write(json)
    if not write_ok then
        msg.error('skip-intro: save_marks: write failed: ' .. tostring(write_err))
        f:close()
        return
    end

    f:close()
    msg.info('skip-intro: save_marks: saved OK to ' .. MARK_FILE)
end

------------------------------------------------------------
-- Mark operations
------------------------------------------------------------

mp.register_script_message('set-mark', function(name)
    local t = get_time_pos()
    if not t then
        mp.osd_message('Cannot read current time')
        return
    end
    if not current_key then
        mp.osd_message('No file loaded')
        return
    end
    if name ~= 'start' and name ~= 'end' then
        mp.osd_message('Invalid mark name: ' .. tostring(name))
        return
    end

    local m = ensure_marks(current_key)
    m[name] = t
    save_marks()
    msg.info(string.format('skip-intro: set %s = %.3f for %s', name, t, current_key))
    mp.osd_message(string.format('Marked %s = %.3f s', name, t), 2)
end)

mp.register_script_message('clear-marks', function()
    if not current_key then
        mp.osd_message('No file loaded')
        return
    end
    marks[current_key] = nil
    save_marks()
    mp.osd_message('Cleared marks for current key', 2)
end)

mp.register_script_message('clear-all-marks', function()
    marks = {}
    save_marks()
    mp.osd_message('Cleared all marks', 2)
end)

mp.register_script_message('goto-mark', function(name)
    local m = current_key and marks[current_key]
    if not m or not m[name] then
        mp.osd_message('Mark not set: ' .. tostring(name))
        return
    end
    mp.commandv('seek', m[name], 'absolute')
    mp.osd_message(string.format('Jumped to %s = %.3f s', name, m[name]), 2)
end)

mp.register_script_message('show-marks', function()
    local m = current_key and marks[current_key]
    local s = m and m.start and fmt(m.start) or 'unset'
    local e = m and m["end"] and fmt(m["end"]) or 'unset'
    local key_display = current_key or 'none'
    mp.osd_message('key=' .. key_display .. '\nstart=' .. s .. '  end=' .. e, 3)
    msg.info('skip-intro: show-marks key=' .. key_display .. ' start=' .. s .. ' end=' .. e)
end)

mp.register_script_message('toggle-auto-start', function()
    auto_skip_start = not auto_skip_start
    save_marks()
    sync_state_to_mpv()
    mp.osd_message('Auto-skip intro: ' .. (auto_skip_start and 'on' or 'off'), 2)
end)

mp.register_script_message('toggle-auto-end', function()
    auto_skip_end = not auto_skip_end
    save_marks()
    sync_state_to_mpv()
    mp.osd_message('Auto-skip outro: ' .. (auto_skip_end and 'on' or 'off'), 2)
end)

------------------------------------------------------------
-- Auto-skip logic
------------------------------------------------------------

local function on_file_loaded()
    local path = mp.get_property('path')
    current_key = key_for(path)
    msg.info('skip-intro: file loaded, key = ' .. tostring(current_key))

    if not current_key then return end

    local m = marks[current_key]
    if auto_skip_start and m and m.start and m.start > 0 then
        mp.add_timeout(0.1, function()
            if key_for(mp.get_property('path')) ~= current_key then return end

            -- 如果 mpv 有 --start 参数（说明恢复了进度或用户指定了起点），
            -- 就不跳片头
            local start_opt = mp.get_property_number('options/start')
            if start_opt and start_opt > 0 then
                msg.info(string.format(
                    'skip-intro: options/start=%.1f, skipping intro seek',
                    start_opt))
                return
            end

            -- 兜底：如果 time-pos 已经大于 start，也不跳
            local cur = mp.get_property_number('time-pos')
            if cur and cur > m.start then
                msg.info(string.format(
                    'skip-intro: already at %.1f s, skipping intro seek',
                    cur))
                return
            end

            mp.commandv('seek', m.start, 'absolute')
            mp.osd_message(string.format('Skipped intro %.1f s', m.start), 1)
        end)
    end

    if m then
        m._end_triggered = false
    end
end

local function on_time_pos_change(_, t)
    if not auto_skip_end then return end
    if not t then return end
    if not current_key then return end

    local m = marks[current_key]
    if not m or not m["end"] then return end
    if m._end_triggered then return end

    if t >= m["end"] - 0.3 then
        m._end_triggered = true
        mp.osd_message('Skipped outro', 1)
        mp.commandv('playlist-next')
    end
end

------------------------------------------------------------
-- Event registration
------------------------------------------------------------

load_marks()
sync_state_to_mpv()

mp.register_event('file-loaded', on_file_loaded)
mp.observe_property('time-pos', 'number', on_time_pos_change)

msg.info('skip-intro.lua loaded, mark file: ' .. MARK_FILE)