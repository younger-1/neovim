-- Tests for vim.ui.select(), including integration with builtins (:tselect, z=).

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local clear = n.clear
local exec_lua = n.exec_lua
local api = n.api
local eq = t.eq
local neq = t.neq
local write_file = t.write_file

before_each(clear)

--- Mock async vim.ui.select impl. Imitates fzf-lua/telescope/snacks: opens
--- a transient floating window, then schedules on_choice to fire on the next
--- event-loop tick (rather than synchronously).
---
--- Sets `_G._captured` so tests can inspect what was passed to vim.ui.select.
--- @param pick integer|nil 1-based index to "pick" (nil cancels).
local function setup_async_picker(pick)
  exec_lua(function()
    _G._captured = nil
    --- @diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      _G._captured = { items = items, opts = opts }
      -- Open a floating window like a real picker would.
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 30,
        height = math.min(#items, 5),
      })
      _G._captured.win = win
      -- Defer the choice so the wait actually has to pump events.
      vim.defer_fn(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if pick then
          on_choice(items[pick], pick)
        else
          on_choice(nil, nil)
        end
      end, 30)
    end
  end, pick)
end

describe('vim.ui.select()', function()
  it('can select an item', function()
    local result = exec_lua [[
      local items = {
        { name = 'Item 1' },
        { name = 'Item 2' },
      }
      local opts = {
        format_item = function(entry)
          return entry.name
        end
      }
      local selected
      local cb = function(item)
        selected = item
      end
      -- inputlist would require input and block the test;
      local choices
      vim.fn.inputlist = function(x)
        choices = x
        return 1
      end
      vim.ui.select(items, opts, cb)
      vim.wait(100, function() return selected ~= nil end)
      return {selected, choices}
    ]]
    eq({ name = 'Item 1' }, result[1])
    eq({
      'Select one of:',
      '1: Item 1',
      '2: Item 2',
    }, result[2])
  end)

  describe('via :tselect', function()
    it('passes items and applies the chosen index', function()
      -- Create dummy source files so the jump succeeds.
      write_file('XselTagA.c', 'int foo;\n')
      write_file('XselTagB.c', 'int foo = 1;\n')
      finally(function()
        os.remove('XselTagA.c')
        os.remove('XselTagB.c')
        os.remove('XselTags')
      end)
      write_file(
        'XselTags',
        '!_TAG_FILE_FORMAT\t2\t/extended format/\n'
          .. 'foo\tXselTagA.c\t/^int foo;$/;"\tv\n'
          .. 'foo\tXselTagB.c\t/^int foo = 1;$/;"\tv\n'
      )

      local got = exec_lua(function()
        vim.opt.tags = 'XselTags'
        local captured ---@type table?
        vim.ui.select = function(items, opts, on_choice)
          captured = { items = items, kind = opts.kind }
          -- Pick the second match.
          on_choice(items[2], 2)
        end
        vim.cmd('tselect foo')
        return {
          kind = captured and captured.kind,
          nitems = captured and #captured.items,
          item1_tag = captured and captured.items[1].tag,
          item2_file = captured and captured.items[2].file,
          bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'),
        }
      end)

      eq('tag', got.kind)
      eq(2, got.nitems)
      eq('foo', got.item1_tag)
      eq('XselTagB.c', got.item2_file)
      -- Picking item 2 should land us in XselTagB.c.
      eq('XselTagB.c', got.bufname)
    end)

    it('keeps the buffer unchanged when the user cancels', function()
      write_file('XselTagA.c', 'int foo;\n')
      write_file('XselTagB.c', 'int foo = 1;\n')
      finally(function()
        os.remove('XselTagA.c')
        os.remove('XselTagB.c')
        os.remove('XselTags')
      end)
      write_file(
        'XselTags',
        '!_TAG_FILE_FORMAT\t2\t/extended format/\n'
          .. 'foo\tXselTagA.c\t/^int foo;$/;"\tv\n'
          .. 'foo\tXselTagB.c\t/^int foo = 1;$/;"\tv\n'
      )

      api.nvim_set_option_value('tags', 'XselTags', {})

      local before = api.nvim_buf_get_name(0)
      exec_lua(function()
        vim.ui.select = function(_, _, on_choice)
          on_choice(nil, nil)
        end
        vim.cmd('tselect foo')
      end)

      eq(before, api.nvim_buf_get_name(0))
    end)
  end)

  describe('via z=', function()
    it('passes items and applies the chosen suggestion', function()
      api.nvim_set_option_value('spell', true, {})
      api.nvim_set_option_value('spelllang', 'en_us', {})

      api.nvim_buf_set_lines(0, 0, -1, false, { 'helo' })

      local got = exec_lua(function()
        vim.cmd('normal! gg0')
        local captured ---@type table?
        vim.ui.select = function(items, opts, on_choice)
          captured = { items = items, kind = opts.kind, prompt = opts.prompt }
          -- Pick the first suggestion.
          on_choice(items[1], 1)
        end
        vim.cmd('normal! z=')
        return {
          kind = captured and captured.kind,
          prompt = captured and captured.prompt,
          item1_word = captured and captured.items[1].word,
          line = vim.api.nvim_buf_get_lines(0, 0, -1, false)[1],
        }
      end)

      eq('spell', got.kind)
      -- prompt should contain the misspelled word
      t.matches('helo', got.prompt)
      -- The first suggestion replaced the bad word.
      t.neq('helo', got.line)
      eq(got.item1_word, got.line)
    end)

    it('keeps the word unchanged when the user cancels', function()
      api.nvim_set_option_value('spell', true, {})
      api.nvim_set_option_value('spelllang', 'en_us', {})

      api.nvim_buf_set_lines(0, 0, -1, false, { 'helo' })

      exec_lua(function()
        vim.cmd('normal! gg0')
        vim.ui.select = function(_, _, on_choice)
          on_choice(nil, nil)
        end
        vim.cmd('normal! z=')
      end)

      eq('helo', api.nvim_buf_get_lines(0, 0, -1, false)[1])
    end)
  end)

  -- The selection step blocks the C caller via vim.wait(). Async pickers
  -- (fzf-lua, telescope, snacks, …) open a transient window and call on_choice
  -- on a later event-loop tick. These tests exercise the wait+resume path for
  -- each integration. If the C caller doesn't allow the picker to repaint or
  -- pump events, these will hang or fail.
  describe('async picker', function()
    it('z= dispatches selection from a deferred callback', function()
      api.nvim_set_option_value('spell', true, {})
      api.nvim_set_option_value('spelllang', 'en_us', {})
      api.nvim_buf_set_lines(0, 0, -1, false, { 'helo' })

      setup_async_picker(1)
      exec_lua(function()
        vim.cmd('normal! gg0z=')
      end)

      neq('helo', api.nvim_buf_get_lines(0, 0, -1, false)[1])
      local kind = exec_lua([[return _G._captured and _G._captured.opts.kind]])
      eq('spell', kind)
    end)

    it(':tselect dispatches selection from a deferred callback', function()
      write_file('XselTagA.c', 'int foo;\n')
      write_file('XselTagB.c', 'int foo = 1;\n')
      finally(function()
        os.remove('XselTagA.c')
        os.remove('XselTagB.c')
        os.remove('XselTags')
      end)
      write_file(
        'XselTags',
        '!_TAG_FILE_FORMAT\t2\t/extended format/\n'
          .. 'foo\tXselTagA.c\t/^int foo;$/;"\tv\n'
          .. 'foo\tXselTagB.c\t/^int foo = 1;$/;"\tv\n'
      )
      api.nvim_set_option_value('tags', 'XselTags', {})

      setup_async_picker(2)
      exec_lua(function()
        vim.cmd('tselect foo')
      end)

      eq('XselTagB.c', api.nvim_eval('expand("%:t")'))
      local kind = exec_lua([[return _G._captured and _G._captured.opts.kind]])
      eq('tag', kind)
    end)

    --- Mock fzf-lua-style picker: opens a floating window with a *terminal*
    --- buffer running a small shell command. When the command exits we treat
    --- the user as having "picked" `pick`. This more closely exercises the
    --- code paths that block real terminal-based pickers in ex-command
    --- contexts (RedrawingDisabled, mode dispatch, terminal_loop, …).
    local function setup_term_picker(pick)
      exec_lua(function()
        _G._captured = nil
        --- @diagnostic disable-next-line: duplicate-set-field
        vim.ui.select = function(items, opts, on_choice)
          _G._captured = { items = items, opts = opts }
          local buf = vim.api.nvim_create_buf(false, true)
          local win = vim.api.nvim_open_win(buf, true, {
            relative = 'editor',
            row = 1,
            col = 1,
            width = 30,
            height = math.min(#items, 5),
          })
          -- Sleep briefly to mimic an interactive terminal session, then exit.
          vim.fn.jobstart({ 'sh', '-c', 'sleep 0.05' }, {
            term = true,
            on_exit = function()
              if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
              end
              if pick then
                on_choice(items[pick], pick)
              else
                on_choice(nil, nil)
              end
            end,
          })
        end
      end, pick)
    end

    it('z= dispatches selection from a terminal-based picker', function()
      api.nvim_set_option_value('spell', true, {})
      api.nvim_set_option_value('spelllang', 'en_us', {})
      api.nvim_buf_set_lines(0, 0, -1, false, { 'helo' })

      setup_term_picker(1)
      exec_lua(function()
        vim.cmd('normal! gg0z=')
      end)

      neq('helo', api.nvim_buf_get_lines(0, 0, -1, false)[1])
    end)

    it(':tselect dispatches selection from a terminal-based picker', function()
      write_file('XselTagA.c', 'int foo;\n')
      write_file('XselTagB.c', 'int foo = 1;\n')
      finally(function()
        os.remove('XselTagA.c')
        os.remove('XselTagB.c')
        os.remove('XselTags')
      end)
      write_file(
        'XselTags',
        '!_TAG_FILE_FORMAT\t2\t/extended format/\n'
          .. 'foo\tXselTagA.c\t/^int foo;$/;"\tv\n'
          .. 'foo\tXselTagB.c\t/^int foo = 1;$/;"\tv\n'
      )
      api.nvim_set_option_value('tags', 'XselTags', {})

      setup_term_picker(2)
      exec_lua(function()
        vim.cmd('tselect foo')
      end)

      eq('XselTagB.c', api.nvim_eval('expand("%:t")'))
    end)

    it(':browse oldfiles dispatches selection from a deferred callback', function()
      finally(function()
        os.remove('XselOldA')
        os.remove('XselOldB')
      end)
      write_file('XselOldA', 'a\n')
      write_file('XselOldB', 'b\n')
      local cwd = exec_lua([[return vim.uv.cwd()]])

      setup_async_picker(2)
      exec_lua(function(cwd_)
        -- v:oldfiles is normally populated via shada; inject directly for the test.
        vim.v.oldfiles = { cwd_ .. '/XselOldA', cwd_ .. '/XselOldB' }
        vim.cmd('browse oldfiles')
        -- :browse oldfiles is async — wait for on_choice to fire and edit the file.
        vim.wait(1000, function()
          return vim.fn.expand('%:t') == 'XselOldB'
        end)
      end, cwd)

      eq('XselOldB', api.nvim_eval('expand("%:t")'))
      local kind = exec_lua([[return _G._captured and _G._captured.opts.kind]])
      eq('oldfiles', kind)
    end)
  end)
end)
