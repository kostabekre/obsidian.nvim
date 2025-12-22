-- notes:
-- obsidian nvim can have multiple workspaces
-- that means either I have to watch both workspaces from the beginning
-- or I have to switch to a different workspace when a user decides to do it too.
-- Or maybe ignore other workspaces watch only the current on
--
-- I foudned that in obsidian.nvim we have ObsidianWorkpspaceSet autocommand,
-- I think I should watch only the current workspace and switch when the autocommand is used.

local api = require "obsidian.api"

local M = {}

---@enum obsidian.filewatch.EventType
M.EventTypes = {
  unknown = 0,
  changed = 1,
  renamed = 2,
  deleted = 3,
}

---@class obsidian.filewatch.CallbackArgs
---@field absolute_path string The absolute path to the changed file.
---@field event obsidian.filewatch.EventType The type of the event.
---@field stat uv.fs_stat.result|? The uv file info.

---Creates default callback if an error occured in fs_event_start.
---@param path string The filepath where error occured.
---@return fun(error: string) Default function which accepts an error.
local make_default_error_cb = function(path)
  return function(error)
    error(table.concat { "obsidian.watch(", path, ")", "encountered an error: ", error })
  end
end

--- Minimal time in milliseconds to allow the event to fire for a single file.
local MIN_INTERVAL = 50
--- The time in milleseconds when the changed files will be send to the client.
local CALLBACK_AFTER_INTERVAL = 500

---@type obsidian.filewatch.CallbackArgs[]
local queue_to_send = {}
---@type uv.uv_timer_t
local queue_timer
---@type uv.uv_fs_event_t[]
local watch_handlers = {}

---@type fun (changed_files: obsidian.filewatch.CallbackArgs[])[]
local subscribers = {}

---Check if the event is not a duplicate or the received name is not `~` or a number.
---@param filename string
---@param last_received_files {[string]: number|?}
---@return boolean
local can_continue_parse_update_event = function(filename, last_received_files)
  local now = vim.uv.now()

  local last_callback_time = last_received_files[filename]

  if last_callback_time then
    if now - last_callback_time < MIN_INTERVAL then
      return false
    end
  end

  last_received_files[filename] = now

  if filename:sub(#filename - 2, #filename) ~= ".md" then
    return false
  end

  return true
end

---Watch the path and notify subscribers if a file is changed or an error occured
---@param path string
---@param opts {recursive: boolean}
---@return uv.uv_fs_event_t
local function watch_path_for_subscribers(path, on_error, opts)
  local watch_handle = vim.uv.new_fs_event()

  assert(watch_handle)

  local flags = {
    watch_entry = false, -- true = if you pass dir, watch the dir inode only, not the dir content
    stat = false, -- true = don't use inotify/kqueue but periodic check, not implemented
    recursive = opts.recursive, -- true = watch dirs inside dirs. For now only works on Windows and MacOS
  }

  ---@type {[string]: number|?}
  local last_received_files = {}

  ---Tracks the changed files and returns them to the client after some time.
  ---@param send_arg obsidian.filewatch.CallbackArgs
  local add_to_queue = function(send_arg)
    table.insert(queue_to_send, send_arg)

    queue_timer:stop()

    queue_timer:start(CALLBACK_AFTER_INTERVAL, 0, function()
      for _, subscriber in ipairs(subscribers) do
        subscriber(queue_to_send)
      end

      queue_to_send = {}
    end)
  end

  local on_watch_handle_update = function(err, filename, events)
    if err then
      on_error(err)
      return
    end

    if not can_continue_parse_update_event(filename, last_received_files) then
      return
    end

    local folder_path = vim.uv.fs_event_getpath(watch_handle)

    local full_path = vim.fs.joinpath(folder_path, filename)

    vim.uv.fs_stat(full_path, function(stat_err, stat)
      local event_type
      if events.change then
        event_type = M.EventTypes.changed
      elseif events.rename then
        event_type = M.EventTypes.renamed
      elseif stat_err then
        event_type = M.EventTypes.deleted
      else
        event_type = M.EventTypes.unknown
      end

      add_to_queue {
        absolute_path = full_path,
        event = event_type,
        stat = stat,
      }
    end)
  end

  local success, err = vim.uv.fs_event_start(watch_handle, path, flags, on_watch_handle_update)

  if not success then
    error("couldn't create fs event! error - " .. err .. ". Path - " .. path)
  end

  return watch_handle
end

---According to uv documentation, handles must be closes before memory is free.
local release_resources = function()
  for _, handle in ipairs(watch_handlers) do
    if handle then
      handle:stop()
      if not handle.is_closing then
        handle:close()
      end
    end
  end

  watch_handlers = {}

  queue_timer:stop()
  if not queue_timer.is_closing then
    queue_timer:close()
  end

  queue_to_send = {}
end

M.start = function()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = release_resources,
  })
end

---Create a watch handler (several if on Linux) which emits an event when a file is changed.
---@param folder_path string The path to the watch folder.
M.watch_new = function(folder_path)
  if not folder_path or folder_path == "" then
    error "Path cannot be empty."
  end

  -- we can watch only one directory at a time
  if not vim.fn.empty(watch_handlers) then
    release_resources()
  end

  local new_timer = vim.uv.new_timer()

  assert(new_timer)

  queue_timer = new_timer

  local default_on_err = make_default_error_cb(folder_path)

  local sysname = api.get_os()

  -- uv doesn't support recursive flag on Linux
  if sysname == api.OSType.Linux then

    -- table.insert(watch_handlers, watch_path_for_subscribers(folder_path, { recursive = false }))
    --
    -- local subfolders = api.get_sub_dirs_from_vault(folder_path)
    --
    -- assert(subfolders)
    --
    -- for _, subfolder in ipairs(subfolders) do
    --   table.insert(watch_handlers, watch_path_for_subscribers(subfolder,, default_on_err, { recursive = false }))
    -- end
  else
    watch_handlers = { watch_path_for_subscribers(folder_path, default_on_err, { recursive = true }) }
  end
end

M.add_subscriber = function(subscriber)
  if not subscriber then
    error "subscriber cannot be null"
  end

  table.insert(subscribers, subscriber)
end

return M
