
local async = {}

local lanes = require("lanes")
local copas = require("copas")
local socket = require("socket")
local unpack = unpack or table.unpack

lanes.configure()

function async.addthread(fn)
   local sskt = socket.bind("*", 0)
   local ch = lanes.linda()
   local future = {}
   local host, port = sskt:getsockname()

   local me
   local sent = false
   copas.addserver(sskt, function(dskt)
      dskt:receive()
      dskt:close()
      sent = true
      if me then
         copas.wakeup(me)
      else
         copas.removeserver(sskt)
      end
      sent = true
   end)

   lanes.gen("*", function()
      local socket = require("socket")
      local function pack(...)
         local ret = { n = select("#", ...) }
         for i = 1, ret.n do
            ret[i] = select(i, ...)
         end
         return ret
      end
      local result = pack(fn())
      ch:send("done", {res = result})
      port = tonumber(port)
      local cskt = socket.tcp()
      local ok = cskt:connect(host, port)
      if ok then 
         cskt:send("done")
      end
      cskt:close()
   end)()

   future.try = function()
      if future.getting == true then
         error("concurrent access to future")
      end
      if not future.res then
         local key, value = ch:receive(0, "done")
         if key then
            future.res = value.res
            future.dead = true
            sskt:close()
         end
      end
      if future.res then
         return future.dead, unpack(future.res, 1, future.res.n)
      end
   end
   future.get = function()
      if future.getting == true then
         error("concurrent access to future")
      end
      me = coroutine.running()
      future.getting = true
      if not future.dead then
         local key, value = ch:receive(0, "done")
         if key then
            future.res = value.res
         else
            if not sent then
               copas.sleep(-1)
            end
            local key, value = ch:receive(0, "done")
            if key then
               future.res = value.res
            end
         end
         copas.removeserver(sskt)
         future.dead = true
      end
      future.getting = false
      if future.res then
         return unpack(future.res, 1, future.res.n)
      end
   end
   setmetatable(future, { __call = future.get })
   return future
end

function async.os_execute(command)
   local future = async.addthread(function()
      return os.execute(command)
   end)
   local ret, typ, cod = future:get()
   if type(ret) == "number" then
      if ret == 0 then
         return true, "exit", 0
      elseif ret < 255 then
         return nil, "signal", ret
      else
         return nil, "exit", math.floor(ret / 255)
      end
   else
      return ret, typ, cod
   end
end

return async

