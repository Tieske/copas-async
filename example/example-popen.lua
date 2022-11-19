
local copas = require("copas")
local async = require("copas.async")

-- local fd = io.popen("for i in `seq 5`; do echo 'thread B says '$i; sleep 1; done; exit 99")
-- while true do
--   local d, e = fd:read("*l")
--   print("got:",d,e)
--   if d == nil then
--     return
--   end
-- end

copas(function()

  copas.addthread(function()
    for i = 1, 10 do
       print("coroutine A says ", i*2)
       copas.sleep(2)
    end
    print("DONE A")
  end)


  -- copas.addthread(function()
  --   print("Result B",async.os_execute("for i in `seq 5`; do echo 'thread B says '$i; sleep 1; done; exit 99"))
  --   print("DONE B")
  -- end)

  copas.addthread(function()
    local fd = async.io_popen("ls /")
    while true do
      local d, e = fd:read("*l")
      print("got:",d,e)
      if d == nil then
        break
      end
      require("socket").sleep(0.5)
    end
    print("DONE C")
  end)


  -- copas.addthread(function()
  --   local fd = async.io_popen("for i in `seq 5`; do echo 'thread B says '$i; sleep 1; done; exit 99")
  --   print"A is open"
  --   require("socket").sleep(4)
  --   -- for i = 1, 10 do
  --   while true do
  --     local data, err = fd:read()

  --     print("received ",data, err)
  --     if err then break end
  --     if data == nil then break end
  --     --copas.sleep(1)
  --   end
  --   print("closing", fd:close())
  --   print("DONE A")
  -- end)

end)

