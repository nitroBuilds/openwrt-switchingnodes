local failover = dofile("luci-app-passwall2/root/usr/share/passwall2/vless_failover.lua")
local function node(id, group, protocol, mode)
	return { [".name"] = id, group = group, protocol = protocol or "vless",
		add_mode = mode or "2", type = "Xray", address = "example.org", port = "443" }
end
local subscriptions = {{remark = "A"}, {remark = "B"}, {remark = "C"}}
local nodes = {node("a1", "A"), node("a2", "A"), node("b1", "B"),
	node("b2", "B"), node("c1", "C"), node("c2", "C")}
local current, state = "a1", {}
for _, expected in ipairs({"b1", "c1", "a2", "b2", "c2", "a1", "b1"}) do
	current, state = failover.next_node(nodes, subscriptions, current, state)
	assert(current == expected, tostring(current) .. " != " .. expected)
end
assert(failover.next_node(nodes, {{remark = "A"}}, "a1", {}) == nil)
assert(failover.next_node(nodes, subscriptions, "missing", {}) == nil)
assert(failover.next_node({node("a1", "A"), node("b1", "B", "vmess")}, subscriptions, "a1", {}) == nil)
assert(failover.next_node({node("a1", "A"), node("b1", "B", "vless", "1")}, subscriptions, "a1", {}) == nil)
assert(failover.next_node({node("a1", "A", "_shunt"), node("b1", "B")}, subscriptions, "a1", {}) == nil)
-- Subscription updates can delete nodes or entire groups; stale cursors are harmless.
assert(failover.next_node(nodes, subscriptions, "a1", {b = "deleted"}) == "b1")
assert(failover.next_node({node("a1", "A"), node("c1", "C")}, subscriptions, "a1", {}) == "c1")
assert(failover.next_node(nodes, {{remark = "a"}, {remark = "A"}, {remark = "b"}}, "a1", {}) == "b1")

-- Exercise the mutation gate with the same API contract as LuCI.
local values = {enabled = "1", vless_failover = "1", node = "a1"}
local commits, writes = 0, 0
local api = {
	TMP_PATH = "/tmp/test-passwall2",
	uci = {
		get = function(_, _, _, key) return values[key] end,
		foreach = function(_, _, kind, fn)
			for _, value in ipairs(kind == "nodes" and nodes or subscriptions) do fn(value) end
		end,
		set = function(_, _, _, key, value) values[key] = value; return true end,
		save = function() return true end
	},
	sys = {call = function() commits = commits + 1; return 0 end},
	fs = {readfile = function() return "{}" end, mkdirr = function() end,
		writefile = function() writes = writes + 1 end},
	jsonc = {parse = function() return {} end, stringify = function() return "{}" end}
}
package.loaded["luci.passwall2.api"] = api
local original_write = io.write
io.write = function() end
assert(not failover.switch("outdated"))
assert(commits == 0 and writes == 0)
values.vless_failover = "0"
assert(not failover.switch("a1"))
assert(commits == 0)
values.vless_failover = "1"
assert(failover.switch("a1"))
assert(values.node == "b1" and commits == 1 and writes == 1)
io.write = original_write
print("VLESS selection and mutation tests passed")
