
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

--[[ produces:

    coroutine A says 1
    thread says hello 1
    coroutine A says 2
    coroutine B will try to get thread value
    coroutine B didn't get a value because thread is not done!
    coroutine B will wait for thread value...
    thread says hello 2
    coroutine A says 3
    thread says hello 3
    coroutine A says 4
    thread says hello 4
    coroutine A says 5
    thread says hello 5
    coroutine A says 6
    coroutine B got value from thread:123
    coroutine A says 7
    coroutine A says 8
    coroutine B slept a bit:   nil    exit    12
    DONE B
    coroutine A says 9
    coroutine A says 10
    DONE A

]]
