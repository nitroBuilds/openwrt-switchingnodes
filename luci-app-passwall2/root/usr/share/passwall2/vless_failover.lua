-- Select subscriptions in UCI order, and rotate nodes within each subscription.
local M = {}

function M.next_node(nodes, subscriptions, current, cursors)
	cursors = cursors or {}
	local groups, order, seen, current_group = {}, {}, {}
	for _, sub in ipairs(subscriptions) do
		local group = (sub.remark or ""):lower()
		if group ~= "" and not seen[group] then
			seen[group] = true
			order[#order + 1] = group
			groups[group] = {}
		end
	end
	for _, node in ipairs(nodes) do
		local group = (node.group or ""):lower()
		if node.protocol == "vless" and node.add_mode == "2"
			and (node.type == "Xray" or node.type == "sing-box")
			and node.address and node.port and groups[group] then
			local id = node[".name"]
			groups[group][#groups[group] + 1] = id
			if id == current then current_group = group end
		end
	end
	-- A manual node or a shunt must never be replaced implicitly.
	if not current_group then return nil end
	cursors[current_group] = current
	local start = 0
	for i, group in ipairs(order) do
		if group == current_group then start = i; break end
	end
	for offset = 1, #order - 1 do
		local group = order[(start + offset - 1) % #order + 1]
		local candidates = groups[group]
		if #candidates > 0 then
			local index = 0
			for i, id in ipairs(candidates) do
				if id == cursors[group] then index = i; break end
			end
			local selected = candidates[index % #candidates + 1]
			cursors[group] = selected
			return selected, cursors
		end
	end
end

-- The init script invokes this while holding the service lock.
function M.switch(expected)
	local api = require "luci.passwall2.api"
	local uci = api.uci
	local config = "passwall2"
	if uci:get(config, "@global[0]", "enabled") ~= "1"
		or uci:get(config, "@global[0]", "vless_failover") ~= "1"
		or uci:get(config, "@global[0]", "node") ~= expected then return false end
	local nodes, subscriptions = {}, {}
	uci:foreach(config, "nodes", function(n) nodes[#nodes + 1] = n end)
	uci:foreach(config, "subscribe_list", function(s) subscriptions[#subscriptions + 1] = s end)
	local path = api.TMP_PATH .. "_tmp/vless_failover.json"
	local cursors = api.jsonc.parse(api.fs.readfile(path) or "{}")
	if type(cursors) ~= "table" then cursors = {} end
	local selected, updated = M.next_node(nodes, subscriptions, expected, cursors)
	if not selected then return false end
	if not uci:set(config, "@global[0]", "node", selected) then return false end
	-- Shell commit avoids triggering another asynchronous service restart.
	if not uci:save(config) then return false end
	local rc = api.sys.call("uci -q commit passwall2")
	if rc ~= 0 then return false end
	api.fs.mkdirr(api.TMP_PATH .. "_tmp")
	api.fs.writefile(path, api.jsonc.stringify(updated))
	io.write(selected)
	return true
end

if arg and arg[1] == "switch" then
	os.exit(M.switch(arg[2]) and 0 or 1)
end

return M
