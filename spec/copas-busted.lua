-- Copas test helper for busted.
-- This module returns a function that will enable Copas async testing.
-- After a test it will clear all copas modules (any package starting with "^copas")
-- and the luasocket modules (any package starting with "^socket").
-- @param default_timeout[opt=20] default timeout for tests in seconds
-- @return copas; the copas module your tests should use (slightly patched)
-- @return done; a function to be called at the end of your test, to 1) ensure
-- Copas' main loop exits (so we can move on to the next test), 2) do test-cleanup.
-- @return settimeout; a function to set the timeout for the current test (to override
-- the default timeout)
return function(default_timeout)
   local copas = require "copas"
   local servers_to_remove = setmetatable({}, {__mode = "v"})
   local tasks_to_cancel = setmetatable({}, {__mode = "v"})
   local client_sockets_to_close = setmetatable({}, {__mode = "v"})

   -- record threads to stop, needed to make copas forcefully exit
   local _addnamedthread = copas.addnamedthread
   copas.addnamedthread = function(name, handler, ...)
      local coro = _addnamedthread(name, handler, ...)
      tasks_to_cancel[#tasks_to_cancel+1] = coro
      return coro
   end

   -- record servers to remove, needed to make copas forcefully exit
   local _addserver = copas.addserver
   copas.addserver = function(socket, handler, ...)
      servers_to_remove[#servers_to_remove+1] = socket
      local newhandler = function(client, ...)
         client_sockets_to_close[#client_sockets_to_close+1] = client
         return handler(client, ...)
      end
      return _addserver(socket, newhandler, ...)
   end

   -- setup timeout timer
   local done
   local timeout = false
   local to_timer = require("copas.timer").new {
      recurring = false,
      delay = default_timeout or 20,
      callback = function()
         done()
         timeout = true
      end
   }

   local function settimeout(to)
      to_timer:arm(to)
   end

   function done()
      -- remove servers
      for k,v in pairs(servers_to_remove) do copas.removeserver(v) end
      -- close clients
      for k,v in pairs(client_sockets_to_close) do v:close() end
      -- cancel tasks
      for k,v in pairs(tasks_to_cancel) do copas.removethread(v) end
      -- cancel timeout timer
      to_timer:cancel()
      -- clear luasocket and copas packages
      for k,v in pairs(package.loaded) do
         if k:match("^copas") or k:match("^socket") then
            package.loaded[k] = nil
         end
      end
      collectgarbage()
      collectgarbage()
      assert(not timeout, "timeout")
   end

   return copas, done, settimeout
end
