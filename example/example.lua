
local copas = require("copas")
local async = require("copas.async")

copas.addthread(function()
   for i = 1, 10 do
      print("coroutine A says ", i)
      copas.sleep(1)
   end
   print("DONE A")
end)

local msg = "hello"

local future = async.addthread(function()
   os.execute("for i in `seq 5`; do echo 'thread says "..msg.." '$i; sleep 1; done")
   return 123
end)

copas.addthread(function()
   copas.sleep(2)
   msg = "world" -- this will not affect the async thread
   print("coroutine B will try to get thread value:")
   local val = future:try()
   if not val then
      print("coroutine B didn't get a value because thread is not done!")
   end
   print("coroutine B will wait for thread value...")
   val = future:get()
   print("coroutine B got value from thread:", val)
   local ret, typ, cod = async.os_execute("sleep 2; exit 12")
   print("coroutine B slept a bit: ", ret, typ, cod)
   print("DONE B")
end)

copas.loop()

