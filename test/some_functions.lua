len = string.len
length = string.len
upper = string.upper
lower = string.lower
find = string.find
match = string.match
sub = string.sub
substr = string.sub
gsub = string.gsub

NULL = {}

-- A couple of handy utility functions.

function file_exists(file_name)
	local file = io.open(file_name)
	if file then
		file:close()
	end
	return file ~= nil
end

function read_file(file_name)
	local file = assert( io.open(file_name, "rb") )
	local s = file:read("*all")
	file:close()
	return s
end

function dirname(file_name)
	local dir = file_name:match"^(.*)[/\\][^/\\]*$"
	return dir or "."
end

function basename(file_name)
	local file = file_name:match"^.*[/\\]([^/\\]*)$"
	return file or file_name
end

function split_ext(file_name)
	local file, ext = file_name:match"^(.*)%.([^/\\%.]*)$"
	return file or file_name, ext or ""
end

function content_type(file_name)
	local _, ext = split_ext(file_name)
	local charset = "; charset=utf-8"
	if lower(ext) == "htm" or lower(ext) == "html" then
		return "text/html" .. charset
	elseif lower(ext) == "rtf" then
		return "application/rtf" .. charset
	else
		return "text/plain" .. charset
	end
end

local invalid = "[" .. '\\/:*?"<>|\r\n' .. "]"
function safe_filename(s, errch)
	s = s or ""
	errch = errch or "_"
	return (s:gsub(invalid, errch))
end

function is_blank(line)
	if not line then return true end
	local s = line:find("^%s*$")
	if s then return true end
	return false
end

function starts_with(s, pat)
	s = s or ""
	return s:match("^" .. pat)
end

function ends_with(s, pat)
	s = s or ""
	return s:match(pat .. "$")
end

function left(s, n)
	s = s or ""
	return n > 0 and s:sub(1, n) or ""
end

function right(s, n)
	s = s or ""
	return n > 0 and s:sub(-n, -1) or ""
end

function ltrim(s)
	s = s or ""
	local first, last = s:find"^%s+"
	if first then
		return s:sub(last+1)
	else
		return s
	end
end

function rtrim(s)
	s = s or ""
	local first, last = s:find"%s+$"
	if first then
		return s:sub(1, first-1)
	else
		return s
	end
end

function trim(s)
	return rtrim(ltrim(s))
end

function first_line(s)
	s = s or ""
	local e = s:find"[\r\n]"
	return e and s:sub(1, e-1) or s
end

function capitalize(s)
	s = s or ""
	return s:sub(1, 1):upper() .. s:sub(2)
end

function table.foreach(t, fun)
	for k, v in pairs(t) do
		local result = fun(k, v)
		if result then return result end
	end
end

function element(s, t)
	local function lookup(k, v)
		return v == s and k or nil
	end
	if type(t) ~= "table" then
		t = { t }
	end
	return table.foreach(t, lookup)
end

function sql_quote(s)
	if s and type(s) == "string" then
		return "'" .. s:gsub("'", "''") .. "'"
	else
		return "NULL"
	end
end

function sql_quote_table(l)
	local r = {}
	for i, v in ipairs(l) do
		r[i] = sql_quote(v)
	end
	return r
end

function identity(x)
	return x
end

function tmerge(...)
	local ts = {...}
	local t = {}
	for _, ti in ipairs(ts) do
		if type(ti) == "table" then
			for k, v in pairs(ti) do
				t[k] = v
			end
		end
	end
	return t
end

local format = string.format
local tconcat = table.concat

function stringify(o, pretty, depth, prefix, references)
	pretty = (pretty == nil) or pretty
	depth = depth or 0
	prefix = prefix or "__SELF__"
	references = references or {}

	if type(o) == "string" then
		return format("%q", o)
	elseif o == NULL then
		return "NULL"
	elseif type(o) ~= "table" then
		return tostring(o)
	else
		if references[tostring(o)] then
			return references[tostring(o)]
		else
			local indent = ""
			local ikeys = {}
			local s = { "{" }
			depth = depth + 1
			references[tostring(o)] = prefix
			for k, v in ipairs(o) do
				ikeys[#ikeys+1] = k
				sk = "[" .. k .. "]"
				refk = sk
				if pretty then indent = ("  "):rep(depth) end
				s[#s+1] = indent .. sk .. " = " .. stringify(v, pretty, depth, prefix..refk, references) .. ","
			end
			for k, v in pairs(o) do if not element(k, ikeys) then
				local sk, refk
				if type(k) == "string" and k:match("^[_%w]+$") then
					sk = k
					refk = "." .. k
				else
					sk = "[" .. stringify(k, pretty, 0, prefix, references) .. "]"
					refk = sk
				end
				if pretty then indent = ("  "):rep(depth) end
				s[#s+1] = indent .. sk .. " = " .. stringify(v, pretty, depth, prefix..refk, references) .. ","
			end end
			if pretty then indent = ("  "):rep(depth-1) end
			s[#s+1] = indent .. "}"
			if #s == 2 then
				return "{}"
			else
				return tconcat(s, pretty and "\n" or "")
			end
		end
      end
end

function stringify_flat(o, depth, prefix, references)
	return stringify(o, false, depth, prefix, references)
end
