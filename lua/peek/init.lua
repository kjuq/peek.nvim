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

-- previewed files, history[history_index] is the one being previewed.
-- line is where the preview was scrolled when it left the file
local history, history_index = {}, 0

-- cursor position whose CursorMoved does not scroll the preview, see go()
local restored_cursor

local function get_buf_content(bufnr)
  return concat(nvim_buf_get_lines(bufnr, 0, -1, false), '\n'):gsub('%s*$', '')
end

local function get_buf_dir(bufnr)
  return vim.fn.fnamemodify(vim.uri_to_fname(vim.uri_from_bufnr(bufnr)), ':p:h')
end

local open

local function push_history(path)
  local current = history[history_index]
  if path ~= '' and not (current and current.path == path) then
    for i = #history, history_index + 1, -1 do
      history[i] = nil
    end
    history_index = history_index + 1
    history[history_index] = { path = path }
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
  local entry = history[index]
  if not entry then
    return
  end

  local restore = entry.line
  -- move the index first so that open() does not push the path again
  -- and scrolls to entry.line
  local prev_index = history_index
  history_index = index
  if not edit(entry.path) then
    history_index = prev_index
  elseif restore then
    -- Neovim restores the cursor after BufEnter and then triggers CursorMoved,
    -- which should not scroll the preview back to the cursor
    restored_cursor = vim.api.nvim_win_get_cursor(vim.fn.bufwinid(preview_bufnr))
  end
end

-- set the task list item on lnum to checked, as clicked in the preview
local function check(lnum, checked)
  local text = nvim_buf_get_lines(preview_bufnr, lnum - 1, lnum, false)[1]
  if not text then
    return
  end

  local mark = checked and 'x' or ' '
  local new
  for _, pattern in ipairs({ '^([%s>]*[-+*]%s+%[)[ xX](%])', '^([%s>]*%d+[.)]%s+%[)[ xX](%])' }) do
    new = text:match(pattern) and text:gsub(pattern, '%1' .. mark .. '%2')
    if new then
      break
    end
  end

  if not new then
    return app.notify('Task list item not found on line ' .. lnum)
  end

  if not vim.bo[preview_bufnr].modifiable then
    return app.notify('Buffer is not modifiable')
  end

  if new ~= text then
    vim.api.nvim_buf_set_lines(preview_bufnr, lnum - 1, lnum, false, { new })
  end
  app.show(get_buf_content(preview_bufnr))
end

local function on_message(msg)
  if not preview_bufnr then
    return
  end

  local entry = history[history_index]

  if msg.action == 'check' and type(msg.line) == 'number' then
    check(msg.line, msg.checked == true)
  elseif msg.action == 'open' and type(msg.path) == 'string' then
    open_link(msg.path)
  elseif msg.action == 'back' then
    go(-1)
  elseif msg.action == 'forward' then
    go(1)
  end

  -- remember where the preview was in the file it has left
  if entry and entry ~= history[history_index] and type(msg.line) == 'number' then
    entry.line = msg.line
  end
end

function open(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local entry = history[history_index]
  -- go() has moved to the entry of this file
  local restore = entry and entry.path == path and entry.line

  augroup = nvim_create_augroup('PeekActiveAugroup', { clear = true })
  preview_bufnr = bufnr
  restored_cursor = nil

  app.init(function()
    augroup = nvim_del_augroup_by_id(augroup)
    history, history_index = {}, 0
  end, on_message)
  app.base(get_buf_dir(bufnr))
  app.show(get_buf_content(bufnr))
  if restore then
    entry.line = nil
  end
  app.scroll(restore or line('.'))
  push_history(path)

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
      local cursor = vim.api.nvim_win_get_cursor(0)
      if not vim.deep_equal(cursor, restored_cursor) then
        restored_cursor = nil
        app.scroll(cursor[1])
      end
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
