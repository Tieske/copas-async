
local copas = require("copas")
local async = require("copas.async")


copas(function()

  -- Adds a Copas based coroutine (NOT running in a Lane)
  copas.addthread(function()
    for i = 1, 10 do
       print("coroutine A says ", i*2)
       copas.sleep(2)
    end
    print("DONE A")
  end)


  -- Runs an os.execute command in a lane, blocking the current coroutine, but letting other coroutines run.
  copas.addthread(function()
    print("Result B",async.os_execute("for i in `seq 5`; do echo 'thread    B says '$i; sleep 1; done; exit 99"))
    print("DONE B")
  end)


  -- Runs a command async through io.popen, reads input line-by-line (the wait implemented Lua-side)
  copas.addthread(function()
    local fd = async.io_popen("ls /")
    while true do
      local d, e = fd:read("*l")
      print("coroutine C got:",d,e)
      if d == nil then
        break
      end
      copas.sleep(0.5)
    end
    print("DONE C")
  end)

  -- Runs a command async through io.popen, reads input line-by-line (the wait in the shell command)
  copas.addthread(function()
    local fd = async.io_popen("for i in `seq 5`; do echo 'says '$i; sleep 1; done; exit 99")
    print"D is open"
    while true do
      local data, err = fd:read()

      print("thread    D ",data, err)
      if err then
        print("thread    D encountered error: ", err)
        break
      end
      if data == nil then
        print("thread    D reached EOF")
        break
      end
    end
    print("closing D", fd:close())
    print("DONE D")
  end)

end)

