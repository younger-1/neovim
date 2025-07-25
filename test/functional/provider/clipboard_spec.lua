-- Test clipboard provider support

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local clear, feed, insert = n.clear, n.feed, n.insert
local expect, eq, eval, source = n.expect, t.eq, n.eval, n.source
local command = n.command
local api = n.api

local function basic_register_test(noblock)
  insert('some words')

  feed('^dwP')
  expect('some words')

  feed('veyP')
  expect('some words words')

  feed('^dwywe"-p')
  expect('wordssome  words')

  feed('p')
  expect('wordssome words  words')

  feed('yyp')
  expect([[
    wordssome words  words
    wordssome words  words]])
  feed('d-')

  insert([[
    some text, and some more
    random text stuff]])
  feed('ggtav+2ed$p')
  expect([[
    some text, stuff and some more
    random text]])

  -- deleting line or word uses "1/"- and doesn't clobber "0
  -- and deleting word to unnamed doesn't clobber "1
  feed('ggyyjdddw"0p"1p"-P')
  expect([[
    text, stuff and some more
    some text, stuff and some more
    some random text]])

  -- delete line doesn't clobber "-
  feed('dd"-P')
  expect([[
    text, stuff and some more
    some some text, stuff and some more]])

  -- deleting a word to named ("a) doesn't update "1 or "-
  feed('gg"adwj"1P^"-P')
  expect([[
    , stuff and some more
    some some random text
    some some text, stuff and some more]])

  -- deleting a line does update ""
  feed('ggdd""P')
  expect([[
    , stuff and some more
    some some random text
    some some text, stuff and some more]])

  feed('ggw<c-v>jwyggP')
  if noblock then
    expect([[
      stuf
      me s
      , stuff and some more
      some some random text
      some some text, stuff and some more]])
  else
    expect([[
      stuf, stuff and some more
      me ssome some random text
      some some text, stuff and some more]])
  end

  -- pasting in visual does unnamed delete of visual selection
  feed('ggdG')
  insert('one and two and three')
  feed('"ayiwbbviw"ap^viwp$viw"-p')
  expect('two and three and one')
end

describe('clipboard', function()
  local screen

  before_each(function()
    clear()
    screen = Screen.new(72, 4)
  end)

  it('unnamed register works without provider', function()
    eq('"', eval('v:register'))
    basic_register_test()
  end)

  it('using "+ in Normal mode with invalid g:clipboard always shows error', function()
    insert('a')
    command("let g:clipboard = 'bogus'")
    feed('"+yl')
    screen:expect([[
      ^a                                                                       |
      {1:~                                                                       }|*2
      clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    ]])
    feed('"+p')
    screen:expect([[
      a^a                                                                      |
      {1:~                                                                       }|*2
      clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    ]])
  end)

  it('using clipboard=unnamedplus with invalid g:clipboard shows error once', function()
    insert('a')
    command("let g:clipboard = 'bogus'")
    command('set clipboard=unnamedplus')
    feed('yl')
    screen:expect([[
      ^a                                                                       |
      {1:~                                                                       }|*2
      clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    ]])
    feed(':<CR>')
    screen:expect([[
      ^a                                                                       |
      {1:~                                                                       }|*2
      :                                                                       |
    ]])
    feed('p')
    screen:expect([[
      a^a                                                                      |
      {1:~                                                                       }|*2
      :                                                                       |
    ]])
  end)

  it('`:redir @+>` with invalid g:clipboard shows exactly one error #7184', function()
    command("let g:clipboard = 'bogus'")
    command('redir @+> | :silent echo system("cat CONTRIBUTING.md") | redir END')
    screen:expect([[
      ^                                                                        |
      {1:~                                                                       }|*2
      clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    ]])
  end)

  it('`:redir @+>|bogus_cmd|redir END` + invalid g:clipboard must not recurse #7184', function()
    command("let g:clipboard = 'bogus'")
    feed(':redir @+> | bogus_cmd | redir END<cr>')
    screen:expect {
      grid = [[
    {3:                                                                        }|
    clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    {9:E492: Not an editor command: bogus_cmd | redir END}                      |
    {6:Press ENTER or type command to continue}^                                 |
    ]],
    }
  end)

  it('invalid g:clipboard shows hint if :redir is not active', function()
    command("let g:clipboard = 'bogus'")
    eq('', eval('provider#clipboard#Executable()'))
    eq('clipboard: invalid g:clipboard', eval('provider#clipboard#Error()'))

    command("let g:clipboard = 'bogus'")
    -- Explicit clipboard attempt, should show a hint message.
    feed(':let @+="foo"<cr>')
    screen:expect([[
      ^                                                                        |
      {1:~                                                                       }|*2
      clipboard: No provider. Try ":checkhealth" or ":h clipboard".           |
    ]])
  end)

  it('valid g:clipboard', function()
    -- provider#clipboard#Executable() only checks the structure.
    api.nvim_set_var('clipboard', {
      ['name'] = 'clippy!',
      ['copy'] = { ['+'] = 'any command', ['*'] = 'some other' },
      ['paste'] = { ['+'] = 'any command', ['*'] = 'some other' },
    })
    eq('clippy!', eval('provider#clipboard#Executable()'))
    eq('', eval('provider#clipboard#Error()'))
  end)

  it('g:clipboard using lists', function()
    source([[let g:clipboard = {
            \  'name': 'custom',
            \  'copy': { '+': ['any', 'command'], '*': ['some', 'other'] },
            \  'paste': { '+': ['any', 'command'], '*': ['some', 'other'] },
            \}]])
    eq('custom', eval('provider#clipboard#Executable()'))
    eq('', eval('provider#clipboard#Error()'))
  end)

  it('g:clipboard using Vimscript functions', function()
    -- Implements a fake clipboard provider. cache_enabled is meaningless here.
    source([[let g:clipboard = {
            \  'name': 'custom',
            \  'copy': {
            \     '+': {lines, regtype -> extend(g:, {'dummy_clipboard_plus': [lines, regtype]}) },
            \     '*': {lines, regtype -> extend(g:, {'dummy_clipboard_star': [lines, regtype]}) },
            \   },
            \  'paste': {
            \     '+': {-> get(g:, 'dummy_clipboard_plus', [])},
            \     '*': {-> get(g:, 'dummy_clipboard_star', [])},
            \  },
            \  'cache_enabled': 1,
            \}]])

    eq('', eval('provider#clipboard#Error()'))
    eq('custom', eval('provider#clipboard#Executable()'))

    eq('', eval("getreg('*')"))
    eq('', eval("getreg('+')"))

    command('call setreg("*", "star")')
    command('call setreg("+", "plus")')
    eq('star', eval("getreg('*')"))
    eq('plus', eval("getreg('+')"))

    command('call setreg("*", "star", "v")')
    eq({ { 'star' }, 'v' }, eval('g:dummy_clipboard_star'))
    command('call setreg("*", "star", "V")')
    eq({ { 'star', '' }, 'V' }, eval('g:dummy_clipboard_star'))
    command('call setreg("*", "star", "b")')
    eq({ { 'star', '' }, 'b' }, eval('g:dummy_clipboard_star'))
  end)

  describe('g:clipboard[paste] Vimscript function', function()
    it('can return empty list for empty clipboard', function()
      source([[let g:dummy_clipboard = []
              let g:clipboard = {
              \  'name': 'custom',
              \  'copy': { '*': {lines, regtype ->  0} },
              \  'paste': { '*': {-> g:dummy_clipboard} },
              \}]])
      eq('', eval('provider#clipboard#Error()'))
      eq('custom', eval('provider#clipboard#Executable()'))
      eq('', eval("getreg('*')"))
    end)

    it('can return a list with a single string', function()
      source([=[let g:dummy_clipboard = ['hello']
              let g:clipboard = {
              \  'name': 'custom',
              \  'copy': { '*': {lines, regtype ->  0} },
              \  'paste': { '*': {-> g:dummy_clipboard} },
              \}]=])
      eq('', eval('provider#clipboard#Error()'))
      eq('custom', eval('provider#clipboard#Executable()'))

      eq('hello', eval("getreg('*')"))
      source([[let g:dummy_clipboard = [''] ]])
      eq('', eval("getreg('*')"))
    end)

    it('can return a list of lines if a regtype is provided', function()
      source([=[let g:dummy_clipboard = [['hello'], 'v']
              let g:clipboard = {
              \  'name': 'custom',
              \  'copy': { '*': {lines, regtype ->  0} },
              \  'paste': { '*': {-> g:dummy_clipboard} },
              \}]=])
      eq('', eval('provider#clipboard#Error()'))
      eq('custom', eval('provider#clipboard#Executable()'))
      eq('hello', eval("getreg('*')"))
    end)

    it('can return a list of lines instead of [lines, regtype]', function()
      source([=[let g:dummy_clipboard = ['hello', 'v']
              let g:clipboard = {
              \  'name': 'custom',
              \  'copy': { '*': {lines, regtype ->  0} },
              \  'paste': { '*': {-> g:dummy_clipboard} },
              \}]=])
      eq('', eval('provider#clipboard#Error()'))
      eq('custom', eval('provider#clipboard#Executable()'))
      eq('hello\nv', eval("getreg('*')"))
    end)
  end)
end)

describe('clipboard (with fake clipboard.vim)', function()
  local function reset(...)
    clear('--cmd', 'set rtp^=test/functional/fixtures', ...)
  end

  before_each(function()
    reset()
    command('call getreg("*")') -- force load of provider
  end)

  it('`:redir @+>` invokes clipboard once-per-message', function()
    eq(0, eval('g:clip_called_set'))
    command('redir @+> | :silent echo system("cat CONTRIBUTING.md") | redir END')
    -- Assuming CONTRIBUTING.md has >100 lines.
    assert(eval('g:clip_called_set') > 100)
  end)

  it('`:redir @">` does NOT invoke clipboard', function()
    -- :redir to a non-clipboard register, with `:set clipboard=unnamed` does
    -- NOT propagate to the clipboard. This is consistent with Vim.
    command('set clipboard=unnamedplus')
    eq(0, eval('g:clip_called_set'))
    command('redir @"> | :silent echo system("cat CONTRIBUTING.md") | redir END')
    eq(0, eval('g:clip_called_set'))
  end)

  it('`:redir @+>|bogus_cmd|redir END` must not recurse #7184', function()
    local screen = Screen.new(72, 4)
    feed(':redir @+> | bogus_cmd | redir END<cr>')
    screen:expect([[
      ^                                                                        |
      {1:~                                                                       }|*2
      {9:E492: Not an editor command: bogus_cmd | redir END}                      |
    ]])
  end)

  it('has independent "* and unnamed registers by default', function()
    insert('some words')
    feed('^"*dwdw"*P')
    expect('some ')
    eq({ { 'some ' }, 'v' }, eval("g:test_clip['*']"))
    eq('words', eval("getreg('\"', 1)"))
  end)

  it('supports separate "* and "+ when the provider supports it', function()
    insert([[
      text:
      first line
      second line
      third line]])

    feed('G"+dd"*dddd"+p"*pp')
    expect([[
      text:
      third line
      second line
      first line]])
    -- linewise selection should be encoded as an extra newline
    eq({ { 'third line', '' }, 'V' }, eval("g:test_clip['+']"))
    eq({ { 'second line', '' }, 'V' }, eval("g:test_clip['*']"))
  end)

  it('handles null bytes when pasting and in getreg', function()
    insert('some\022000text\n\022000very binary\022000')
    feed('"*y-+"*p')
    eq({ { 'some\ntext', '\nvery binary\n', '' }, 'V' }, eval("g:test_clip['*']"))
    expect('some\00text\n\00very binary\00\nsome\00text\n\00very binary\00')

    -- test getreg/getregtype
    eq('some\ntext\n\nvery binary\n\n', eval("getreg('*', 1)"))
    eq('V', eval("getregtype('*')"))

    -- getreg supports three arguments
    eq('some\ntext\n\nvery binary\n\n', eval("getreg('*', 1, 0)"))
    eq({ 'some\ntext', '\nvery binary\n' }, eval("getreg('*', 1, 1)"))
  end)

  it('autodetects regtype', function()
    command("let g:test_clip['*'] = ['linewise stuff','']")
    command("let g:test_clip['+'] = ['charwise','stuff']")
    eq('V', eval("getregtype('*')"))
    eq('v', eval("getregtype('+')"))
    insert('just some text')
    feed('"*p"+p')
    expect([[
      just some text
      lcharwise
      stuffinewise stuff]])
  end)

  it('support blockwise operations', function()
    insert([[
      much
      text]])
    command("let g:test_clip['*'] = [['very','block'],'b']")
    feed('gg"*P')
    expect([[
      very much
      blocktext]])
    eq('\0225', eval("getregtype('*')"))
    feed('gg4l<c-v>j4l"+ygg"+P')
    expect([[
       muchvery much
      ktextblocktext]])
    eq({ { ' much', 'ktext', '' }, 'b' }, eval("g:test_clip['+']"))
  end)

  it('supports setreg()', function()
    command('call setreg("*", "setted\\ntext", "c")')
    command('call setreg("+", "explicitly\\nlines", "l")')
    feed('"+P"*p')
    expect([[
        esetted
        textxplicitly
        lines
        ]])
    command('call setreg("+", "blocky\\nindeed", "b")')
    feed('"+p')
    expect([[
        esblockyetted
        teindeedxtxplicitly
        lines
        ]])
  end)

  it('supports :let @+ (issue #1427)', function()
    command("let @+ = 'some'")
    command("let @* = ' other stuff'")
    eq({ { 'some' }, 'v' }, eval("g:test_clip['+']"))
    eq({ { ' other stuff' }, 'v' }, eval("g:test_clip['*']"))
    feed('"+p"*p')
    expect('some other stuff')
    command("let @+ .= ' more'")
    feed('dd"+p')
    expect('some more')
  end)

  it('pastes unnamed register if the provider fails', function()
    insert('the text')
    feed('yy')
    command('let g:cliperror = 1')
    feed('"*p')
    expect([[
      the text
      the text]])
  end)

  describe('with clipboard=unnamed', function()
    -- the basic behavior of unnamed register should be the same
    -- even when handled by clipboard provider
    before_each(function()
      feed(':set clipboard=unnamed<cr>')
    end)

    it('works', function()
      basic_register_test()
    end)

    it('works with pure text clipboard', function()
      command('let g:cliplossy = 1')
      -- expect failure for block mode
      basic_register_test(true)
    end)

    it('links the "* and unnamed registers', function()
      -- with cb=unnamed, "* and unnamed will be the same register
      insert('some words')
      feed('^"*dwdw"*P')
      expect('words')
      eq({ { 'words' }, 'v' }, eval("g:test_clip['*']"))

      -- "+ shouldn't have changed
      eq({ '' }, eval("g:test_clip['+']"))

      command("let g:test_clip['*'] = ['linewise stuff','']")
      feed('p')
      expect([[
        words
        linewise stuff]])
    end)

    it('does not clobber "0 when pasting', function()
      insert('a line')
      feed('yy')
      command("let g:test_clip['*'] = ['b line','']")
      feed('"0pp"0p')
      expect([[
        a line
        a line
        b line
        a line]])
    end)

    it('supports v:register and getreg() without parameters', function()
      eq('*', eval('v:register'))
      command("let g:test_clip['*'] = [['some block',''], 'b']")
      eq('some block', eval('getreg()'))
      eq('\02210', eval('getregtype()'))
    end)

    it('yanks visual selection when pasting', function()
      insert('indeed visual')
      command("let g:test_clip['*'] = [['clipboard'], 'c']")
      feed('viwp')
      eq({ { 'visual' }, 'v' }, eval("g:test_clip['*']"))
      expect('indeed clipboard')

      -- explicit "* should do the same
      command("let g:test_clip['*'] = [['star'], 'c']")
      feed('viw"*p')
      eq({ { 'clipboard' }, 'v' }, eval("g:test_clip['*']"))
      expect('indeed star')
    end)

    it('unnamed operations work even if the provider fails', function()
      insert('the text')
      feed('yy')
      command('let g:cliperror = 1')
      feed('p')
      expect([[
        the text
        the text]])
    end)

    it('is updated on global changes', function()
      insert([[
	text
	match
	match
	text
      ]])
      command('g/match/d')
      eq('match\n', eval('getreg("*")'))
      feed('u')
      eval('setreg("*", "---")')
      command('g/test/')
      feed('<esc>')
      eq('---', eval('getreg("*")'))
    end)

    it('works in the cmdline window', function()
      feed('q:itext<esc>yy')
      eq({ { 'text', '' }, 'V' }, eval("g:test_clip['*']"))
      command("let g:test_clip['*'] = [['star'], 'c']")
      feed('p')
      eq('textstar', api.nvim_get_current_line())
    end)

    it('block paste works correctly', function()
      insert([[
        aabbcc
        ddeeff
      ]])
      feed('gg^<C-v>') -- Goto start of top line enter visual block mode
      feed('3ljy^k') -- yank 4x2 block & goto initial location
      feed('P') -- Paste it before cursor
      expect([[
        aabbaabbcc
        ddeeddeeff
      ]])
    end)

    it('block paste computes block width correctly #35034', function()
      insert('あいうえお')
      feed('0<C-V>ly')
      feed('P')
      expect('あいあいうえお')
      feed('A\nxxx\nxx<Esc>')
      feed('0<C-V>kkly')
      feed('P')
      expect([[
        あいあいあいうえお
        xxx xxx
        xx  xx]])
    end)
  end)

  describe('clipboard=unnamedplus', function()
    before_each(function()
      feed(':set clipboard=unnamedplus<cr>')
    end)

    it('links the "+ and unnamed registers', function()
      eq('+', eval('v:register'))
      insert('one two')
      feed('^"+dwdw"+P')
      expect('two')
      eq({ { 'two' }, 'v' }, eval("g:test_clip['+']"))

      -- "* shouldn't have changed
      eq({ '' }, eval("g:test_clip['*']"))

      command("let g:test_clip['+'] = ['three']")
      feed('p')
      expect('twothree')
    end)

    it('and unnamed, yanks to both', function()
      command('set clipboard=unnamedplus,unnamed')
      insert([[
        really unnamed
        text]])
      feed('ggdd"*p"+p')
      expect([[
        text
        really unnamed
        really unnamed]])
      eq({ { 'really unnamed', '' }, 'V' }, eval("g:test_clip['+']"))
      eq({ { 'really unnamed', '' }, 'V' }, eval("g:test_clip['*']"))

      -- unnamedplus takes precedence when pasting
      eq('+', eval('v:register'))
      command("let g:test_clip['+'] = ['the plus','']")
      command("let g:test_clip['*'] = ['the star','']")
      feed('p')
      expect([[
        text
        really unnamed
        really unnamed
        the plus]])
    end)

    it('is updated on global changes', function()
      insert([[
	text
	match
	match
	text
      ]])
      command('g/match/d')
      eq('match\n', eval('getreg("+")'))
      feed('u')
      eval('setreg("+", "---")')
      command('g/test/')
      feed('<esc>')
      eq('---', eval('getreg("+")'))
    end)
  end)

  it('sets v:register after startup', function()
    reset()
    eq('"', eval('v:register'))
    reset('--cmd', 'set clipboard=unnamed')
    eq('*', eval('v:register'))
  end)

  it('supports :put', function()
    insert('a line')
    command("let g:test_clip['*'] = ['some text']")
    command("let g:test_clip['+'] = ['more', 'text', '']")
    command(':put *')
    expect([[
    a line
    some text]])
    command(':put +')
    expect([[
    a line
    some text
    more
    text]])
  end)

  it('supports "+ and "* in registers', function()
    local screen = Screen.new(60, 10)
    feed(":let g:test_clip['*'] = ['some', 'star data','']<cr>")
    feed(":let g:test_clip['+'] = ['such', 'plus', 'stuff']<cr>")
    feed(':registers<cr>')
    screen:expect(
      [[
                                                                  |
      {0:~                                                           }|*2
      {4:                                                            }|
      :registers                                                  |
      {1:Type Name Content}                                           |
        l  "*   some{2:^J}star data{2:^J}                                 |
        c  "+   such{2:^J}plus{2:^J}stuff                                 |
        c  ":   let g:test_clip['+'] = ['such', 'plus', 'stuff']  |
      {3:Press ENTER or type command to continue}^                     |
    ]],
      {
        [0] = { bold = true, foreground = Screen.colors.Blue },
        [1] = { bold = true, foreground = Screen.colors.Fuchsia },
        [2] = { foreground = Screen.colors.Blue },
        [3] = { bold = true, foreground = Screen.colors.SeaGreen },
        [4] = { bold = true, reverse = true },
      }
    )
    feed('<cr>') -- clear out of Press ENTER screen
  end)

  it('can paste "* to the commandline', function()
    insert('s/s/t/')
    feed('gg"*y$:<c-r>*<cr>')
    expect('t/s/t/')
    command("let g:test_clip['*'] = ['s/s/u']")
    feed(':<c-r>*<cr>')
    expect('t/u/t/')
  end)

  it('supports :redir @*>', function()
    command("let g:test_clip['*'] = ['stuff']")
    command('redir @*>')
    -- it is made empty
    eq({ { '' }, 'v' }, eval("g:test_clip['*']"))
    feed(':let g:test = doesnotexist<cr>')
    feed('<cr>')
    eq(
      { {
        '',
        '',
        'E121: Undefined variable: doesnotexist',
      }, 'v' },
      eval("g:test_clip['*']")
    )
    feed(':echo "Howdy!"<cr>')
    eq({
      {
        '',
        '',
        'E121: Undefined variable: doesnotexist',
        '',
        'Howdy!',
      },
      'v',
    }, eval("g:test_clip['*']"))
  end)

  it('handles middleclick correctly', function()
    command('set mouse=a')

    local screen = Screen.new(30, 5)
    insert([[
      the source
      a target]])
    feed('gg"*ywwyw')
    -- clicking depends on the exact visual layout, so expect it:
    screen:expect([[
      the ^source                    |
      a target                      |
      {1:~                             }|*2
                                    |
    ]])

    feed('<MiddleMouse><0,1>')
    expect([[
      the source
      the a target]])

    -- on error, fall back to unnamed register
    command('let g:cliperror = 1')
    feed('<MiddleMouse><6,1>')
    expect([[
      the source
      the a sourcetarget]])
  end)

  it('setreg("*") with clipboard=unnamed #5646', function()
    source([=[
      function! Paste_without_yank(direction) range
        let [reg_save,regtype_save] = [getreg('*'), getregtype('*')]
        normal! gvp
        call setreg('*', reg_save, regtype_save)
      endfunction
      xnoremap p :call Paste_without_yank('p')<CR>
      set clipboard=unnamed
    ]=])
    insert('some words')
    feed('gg0yiw')
    feed('wviwp')
    expect('some some')
    eq('some', eval('getreg("*")'))
  end)

  it('does not fall back to unnamed register with getreg() #24257', function()
    eval('setreg("", "wrong")')
    command('let g:cliperror = 1')
    eq('', eval('getreg("*")'))
    eq('', eval('getreg("+")'))
  end)
end)
