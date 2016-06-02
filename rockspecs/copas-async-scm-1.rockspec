
package = "Copas-Async"
version = "scm-1"

source = {
   url = "git://github.com/hishamhm/copas-async",
}

description = {
   summary = "Copas add-on to provide true asynchronus threads",
   detailed = [[
      Copas-friendly true asynchronous threads, powered by Lua Lanes.
   ]],
}

dependencies = {
   "lua >= 5.1",
   "lanes >= 3.10.0",
   "copas >= 2.0.1",
}

build = {
   type = "builtin",
   modules = {
      ["copas.async"] = "src/copas/async.lua",
   },
}
