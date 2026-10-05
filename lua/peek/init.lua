local app = require('peek.app')
local config = require('peek.config')
local throttle = require('peek.throttle')

local nvim_buf_get_lines = vim.api.nvim_buf_get_lines
local nvim_create_augroup = vim.api.nvim_create_augroup
local nvim_create_autocmd = vim.api.nvim_create_autocmd
local nvim_del_augroup_by_id = vim.api.nvim_del_augroup_by_id
local concat = table.concat
local line = vim.fn.line

local module = {}

local augroup, throttle_at, throttle_time, initialized, preview_bufnr

-- paths of previewed files, history[history_index] is the one being previewed
local history, history_index = {}, 0

local function get_buf_content(bufnr)
  return concat(nvim_buf_get_lines(bufnr, 0, -1, false), '\n'):gsub('%s*$', '')
end

local function get_buf_dir(bufnr)
  return vim.fn.fnamemodify(vim.uri_to_fname(vim.uri_from_bufnr(bufnr)), ':p:h')
end

local open

local function push_history(path)
  if path ~= '' and history[history_index] ~= path then
    for i = #history, history_index + 1, -1 do
      history[i] = nil
    end
    history_index = history_index + 1
    history[history_index] = path
  end
  app.history(history_index > 1, history_index < #history)
end

-- edit path in the window showing the previewed buffer and preview it
local function edit(path)
  local winid = vim.fn.bufwinid(preview_bufnr)
  local ok, result = pcall(vim.api.nvim_win_call, winid ~= -1 and winid or 0, function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end)

  if not ok then
    vim.api.nvim_notify('Peek error: ' .. result, vim.log.levels.ERROR, {})
    return false
  end

  -- with auto_load, BufEnter has already switched the preview
  if result ~= preview_bufnr then
    open(result)
  end

  return true
end

-- find the linked file like gf: relative to the previewed file first, then in 'path'
local function resolve_link(link)
  local names = { link:sub(1, 1) == '/' and link or get_buf_dir(preview_bufnr) .. '/' .. link }
  if not link:match('^%.%.?/') then
    table.insert(names, (link:gsub('^/', '')))
  end

  return vim.api.nvim_buf_call(preview_bufnr, function()
    for _, name in ipairs(names) do
      local found = vim.fn.findfile(name)
      if found ~= '' then
        return vim.fn.simplify(vim.fn.fnamemodify(found, ':p'))
      end
    end
  end)
end

local function open_link(link)
  local path = resolve_link(link)

  if not path then
    return app.notify('File "' .. link .. '" not found')
  end

  local filetype = vim.filetype.match({ filename = path })
  if not vim.tbl_contains(config.get('filetype'), filetype) then
    return app.notify('File type "' .. (filetype or 'unknown') .. '" is not supported')
  end

  edit(path)
end

local function go(offset)
  local index = history_index + offset
  if not history[index] then
    return
  end

  -- move the index first so that open() does not push the path again
  local prev_index = history_index
  history_index = index
  if not edit(history[index]) then
    history_index = prev_index
  end
end

local function on_message(msg)
  if not preview_bufnr then
    return
  end

  if msg.action == 'open' and type(msg.path) == 'string' then
    open_link(msg.path)
  elseif msg.action == 'back' then
    go(-1)
  elseif msg.action == 'forward' then
    go(1)
  end
end

function open(bufnr)
  augroup = nvim_create_augroup('PeekActiveAugroup', { clear = true })
  preview_bufnr = bufnr

  app.init(function()
    augroup = nvim_del_augroup_by_id(augroup)
    history, history_index = {}, 0
  end, on_message)
  app.base(get_buf_dir(bufnr))
  app.show(get_buf_content(bufnr))
  app.scroll(line('.'))
  push_history(vim.api.nvim_buf_get_name(bufnr))

  local show_throttled = throttle(function(content)
    if augroup then
      app.show(content)
    end
  end)

  local function show()
    local content = get_buf_content(bufnr)
    local len = #content

    if len > throttle_at then
      show_throttled:set_timeout(throttle_time or len / 200)
      return show_throttled(content)
    end

    app.show(content)
  end

  nvim_create_autocmd('BufWritePost', {
    group = augroup,
    buffer = bufnr,
    callback = function()
      app.show(get_buf_content(bufnr))
    end,
  })

  nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      app.scroll(line('.'))
    end,
  })

  if config.get('close_on_bdelete') then
    nvim_create_autocmd('BufDelete', {
      group = augroup,
      buffer = bufnr,
      callback = function()
        app.stop()
      end,
    })
  end

  if config.get('update_on_change') then
    nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
      group = augroup,
      buffer = bufnr,
      callback = show,
    })
  end

  if config.get('auto_load') then
    nvim_create_autocmd('BufEnter', {
      group = augroup,
      callback = function(arg)
        if vim.tbl_contains(config.get('filetype'), vim.bo[arg.buf].filetype) then
          show_throttled:clear()
          open(arg.buf)
        end
      end,
    })
  end
end

local function ensure_init(fn)
  return function(...)
    if not initialized then
      module.setup()
    end
    return fn(...)
  end
end

module.open = ensure_init(function()
  local bufnr = vim.api.nvim_get_current_buf()
  local filetype = config.get('filetype')

  if not vim.tbl_contains(filetype, vim.bo[bufnr].filetype) then
    ---@diagnostic disable-next-line: param-type-mismatch
    return vim.api.nvim_notify('Not a supported filetype: ' .. table.concat(filetype, ', '), vim.log.levels.WARN, {})
  end

  open(bufnr)
end)

module.close = ensure_init(function()
  app.stop()
end)

module.is_open = ensure_init(function()
  return not not augroup
end)

function module.setup(cfg)
  config.setup(cfg)
  app.setup()
  throttle_at = config.get('throttle_at')
  throttle_time = tonumber(config.get('throttle_time'))
  initialized = true
end

return module
