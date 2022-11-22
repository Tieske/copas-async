
describe("copas-async", function()

   local copas, socket, async
   local servers_to_remove, tasks_to_cancel, client_sockets_to_close
   local to_timer, done, timeout

   before_each(function()
      copas = require "copas"
      async = require "copas.async"
      socket = require "socket"
      servers_to_remove = setmetatable({}, {__mode = "v"})
      tasks_to_cancel = setmetatable({}, {__mode = "v"})
      client_sockets_to_close = setmetatable({}, {__mode = "v"})

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
      timeout = false
      to_timer = require("copas.timer").new {
         recurring = false,
         delay = 20,
         callback = function()
            done()
            timeout = true
         end
      }
   end)


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


   after_each(function()
      done()
   end)



   describe("futures:", function()

      it("waiting for future:get()", function()
         local result = {}
         copas(function()
            local future = async.addthread(function()
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            end)
            local starttime = socket.gettime()
            result.returned = { future:get() }
            result.duration = socket.gettime() - starttime
            done()
         end)
         assert.same({"hello", "world"}, result.returned)
         assert.near(3, 0.1, result.duration)
      end)


      it("calling future:get() after it's done", function()
         local result = {}
         copas(function()
            local future = async.addthread(function()
               return "hello", "world"
            end)
            copas.sleep(3)
            result = { future:get() }
            done()
         end)
         assert.same({"hello", "world"}, result)
      end)


      it("waiting for future:try()", function()
         local result = {}
         copas(function()
            local future = async.addthread(function()
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            end)
            copas.sleep(0.5)
            for i = 1, 4 do
               result[#result+1] = { future:try() }
               copas.sleep(1)
            end
            done()
         end)
         assert.same({ {false}, {false}, {false}, {true, "hello", "world"}}, result)
      end)


      it("calling future:try() after it's done", function()
         local result = {}
         copas(function()
            local future = async.addthread(function()
               return "hello", "world"
            end)
            copas.sleep(3)
            result = { future:try() }
            done()
         end)
         assert.same({true, "hello", "world"}, result)
      end)


      it("cocurrent access to future errors", function()
         local result = {}
         copas(function()
            local future = async.addthread(function()
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            end)
            copas.addthread(function()
               result.success = { future:get() }
               done()
            end)
            copas.sleep(0.1) -- ensure the 'get' is in progress
            copas.addthread(function() -- test future:try
               result.try = { pcall(future.try, future) }
            end)
            copas.addthread(function() -- test future:get
               result.get = { pcall(future.get, future) }
            end)
         end)
         assert(result.get[2]:match("concurrent access to future"))
         assert(result.try[2]:match("concurrent access to future"))
         assert.same({"hello", "world"}, result.success)
      end)

   end) -- futures



   describe("os_execute:", function()

      it("returns the exit code on success", function()
         local r, t, c
         copas(function()
            r, t, c = async.os_execute("sleep 1")
            done()
         end)
         assert.same(true, r)
         assert.same("exit", t)
         assert.same(0, c)
      end)


      it("returns the exit code on failure", function()
         local r, t, c
         copas(function()
            r, t, c = async.os_execute("sleep 1; exit 123")
            done()
         end)
         assert.same(nil, r)
         assert.same("exit", t)
         assert.same(123, c)
      end)

   end) -- os_execute



   describe("io_popen", function()

      it("Read all at once", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
            copas.sleep(1)
            result.read = { fd:read("*a") }
            result.exit = { fd:close() }
            done()
         end)
         assert.same({
            read = { "1\n2\n3\n4\n" },
            exit = { true, "exit", 0 },
         }, result)
      end)


      it("Read line by line", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
            result.read = {}
            for i = 1, 4 do
               result.read[i] = fd:read("*l")
            end
            result.exit = { fd:close() }
            done()
         end)
         assert.same({
            read = { "1", "2", "3", "4" },
            exit = { true, "exit", 0 },
         }, result)
      end)


      it("Read using fd:lines()", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
            result.read = {}
            for line in fd:lines() do
               result.read[#result.read+1] = line
            end
            result.exit = { fd:close() }
            done()
         end)
         assert.same({
            read = { "1", "2", "3", "4" },
            exit = { true, "exit", 0 },
         }, result)
      end)


      it("closing while incomplete", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; sleep 1; done")
            result.read = {}
            result.read[1] = fd:read("*l") -- read only 1 of the 4 lines
            result.exit = { fd:close() }
            -- this will result in a number of "broken pipe" messages
            -- and the close call will take several seconds until the
            -- entire command exited
            done()
         end)
         assert.same({
            read = { "1" },
            exit = { true, "exit", 0 },
         }, result)
      end)

   end) -- io_popen

end)
