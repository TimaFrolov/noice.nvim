local require = require("noice.util.lazy")

local Config = require("noice.config")
local Manager = require("noice.message.manager")
local Router = require("noice.message.router")
local Util = require("noice.util")

---@alias NoiceEvent MsgEvent|CmdlineEvent|NotifyEvent|LspEvent
---@alias NoiceKind MsgKind|NotifyLevel|LspKind

local M = {}
M._attached = false

---@type table<string, table|false>
M._handlers = {}

local queue = {}

local timer = (vim.uv or vim.loop).new_timer()
local processing = false

function M.process_queue()
  processing = true
  timer:stop()
  while #queue > 0 do
    local item = table.remove(queue, 1)
    M.ui_attach_cb(vim.F.unpack_len(item))
  end
  processing = false
end

function M.setup()
  local widgets = {
    messages = "msg",
    cmdline = "cmdline",
    popupmenu = "popupmenu",
  }

  -- Check if we're running inside a GUI that already externalizes some widgets
  ---@type table<string, boolean>
  local ui_widgets = {}
  local uis = vim.api.nvim_list_uis()
  for _, ui in ipairs(uis) do
    for ext, _ in pairs(widgets) do
      if ui["ext_" .. ext] then
        ui_widgets[ext] = true
      end
    end
  end

  M._handlers = {}

  ---@type table<string, boolean>
  local options = {}
  for ext, widget in pairs(widgets) do
    -- only enable if configured and not enabled in the GUI
    if Config.options[ext].enabled and not ui_widgets[ext] then
      options["ext_" .. ext] = true
      M._handlers[widget] = _G.require("noice.ui." .. widget)
    else
      if ui_widgets[ext] and Config.options.debug then
        Util.warn("Disabling ext_" .. ext)
      end
      M._handlers[widget] = false
    end
  end
  return options
end

local stack_level = 0
function M.ui_attach_cb(handler, event, kind, ...)
  if stack_level > 50 then
    return Util.panic("Event loop detected. Shutting down...")
  end
  stack_level = stack_level + 1

  local tick = Manager.tick()
  M.safe_handle(handler, event, kind, ...)

  -- check if we need to update the ui
  if Manager.tick() > tick then
    if
      require("noice.util.ffi").textlock == 0
      and Util.is_blocking()
      and event ~= "msg_ruler"
      and kind ~= "search_count"
    then
      Util.try(Router.update)
    end
  else
    local widget = M.parse_event(event)
    Util.stats.track(widget .. ".skipped")
  end
  stack_level = stack_level - 1
end

function M.enable()
  local options = M.setup()

  if vim.tbl_isempty(options) then
    if Config.options.debug then
      vim.schedule(function()
        Util.warn("No extensions enabled")
      end)
    end
    return
  end

  if options.ext_messages then
    require("noice.ui.msg").setup()
  end

  M._attached = true

  local schedule_process = vim.schedule_wrap(M.process_queue)

  ---@diagnostic disable-next-line: redundant-parameter
  vim.ui_attach(Config.ns, options, function(event, kind, ...)
    if Util.is_exiting() then
      return
    end
    -- HACK: special case for return prompts
    if event == "msg_show" and kind == "return_prompt" then
      vim.api.nvim_input("<cr>")
      return true
    end
    if Config.options.debug then
      Util.debug({ event = event, kind = kind, ... })
    end
    local handler = M.get_handler(event, kind, ...)
    if not handler then
      return
    end
    table.insert(queue, vim.F.pack_len(handler, event, kind, ...))
    if vim.in_fast_event() then
      timer:start(0, 0, schedule_process)
    elseif not processing then
      M.process_queue()
    end
    -- make sure only Noice handles these events
    return true
  end)

  vim.api.nvim_create_autocmd("SwapExists", {
    group = vim.api.nvim_create_augroup("noice-swap-exists", { clear = true }),
    callback = function()
      Util.try(Router.update)
    end,
  })
end

function M.redirect()
  M.disable()
  Router.echo_pending()
  vim.schedule(M.enable)
end

function M.disable()
  if M._attached then
    M._attached = false
    vim.ui_detach(Config.ns)
  end
end

---@return string, string
function M.parse_event(event)
  return event:match("([a-z]+)_(.*)")
end

---@param event string
function M.get_handler(event, ...)
  local event_group, event_type = event:match("([a-z]+)_(.*)")
  local on = "on_" .. event_type

  local handler = M._handlers[event_group]

  -- false means this is a disabled handler
  if handler == false then
    return
  end

  if not handler then
    if Config.options.debug then
      vim.schedule(function()
        Util.error_once("No ui router for " .. event_group)
      end)
    end
    return
  end

  if type(handler[on]) ~= "function" then
    local args = { ... }
    if Config.options.debug then
      vim.schedule(function()
        Util.error_once(
          "No ui router for **"
            .. event
            .. "** events\n```lua\n"
            .. vim.inspect({ group = event_group, on = on, args = args })
            .. "\n```"
        )
      end)
    end
    return
  end

  return handler[on]
end

---@param handler fun(...)
---@param event string
function M.handle(handler, event, ...)
  handler(event, ...)
end
M.safe_handle = Util.protect(M.handle, { msg = "An error happened while handling a ui event" })

return M
