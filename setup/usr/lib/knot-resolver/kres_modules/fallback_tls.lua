-- Fallback to policy.TLS_FORWARD on non-NOERROR response or timeout from default policy.FORWARD

local ffi = require('ffi')
local kres = require('kres')
ffi.cdef("void kr_server_selection_init(struct kr_query *qry);")

local M = {
	layer = {},
	action = policy.TLS_FORWARD({
		-- TLS fallback forwarders
		{'1.1.1.1', hostname='cloudflare-dns.com'},
		{'9.9.9.10', hostname='dns10.quad9.net'},
		{'76.76.2.11', hostname='p0.freedns.controld.com'},
		{'86.54.11.100', hostname='unfiltered.joindns4.eu'}
	}),
}

local switched = {}

local function check_query(req)
	local qry = req:current()
	if not qry or qry.flags.CACHED or not qry.flags.FORWARD then
		return nil
	end
	return qry
end

local function do_fallback(state, req, qry)
	local key = tostring(req)
	if switched[key] then
		return false
	end
	switched[key] = true

	local domain = kres.dname2str(qry.sname)
	event.after(0, function()
		cache.clear(domain, true)
	end)

	log_debug(ffi.C.LOG_GRP_POLICY, '[fallback_tls] => domain %s, switching from FORWARD to TLS_FORWARD', domain)

	-- Reset current forwarding
	if req.selection_context and req.selection_context.forwarding_targets then
		req.selection_context.forwarding_targets.len = 0
	end

	-- Reset failure counter
	if req.count_fail_row ~= nil then
		req.count_fail_row = 0
	end

	M.action(state, req)
	ffi.C.kr_server_selection_init(qry)

	return true
end

-- Consume reply from upstream or from cache
function M.layer.consume(state, req, pkt)
	local qry = check_query(req)
	if not qry then
		return state
	end

	-- Timeout/transport errors
	if not pkt then
		if do_fallback(state, req, qry) then
			return kres.FAIL
		end
		return state
	end

	if pkt:rcode() == kres.rcode.NOERROR then
		return state
	end

	if do_fallback(state, req, qry) then
		return kres.FAIL
	end
	return state
end

-- Finish for this request
function M.layer.finish(state, req)
	local key = tostring(req)
	switched[key] = nil
	return state
end

return M
