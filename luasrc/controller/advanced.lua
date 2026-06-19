module("luci.controller.advanced",package.seeall)
local io = require "io"
local ltn12 = require "luci.ltn12"
require "nixio.fs"
local nixio = require "nixio"
local u = require "luci.util"
local translate = luci.i18n.translate

function action_get_config()
    local uci = require "luci.model.uci".cursor()
    local conf = uci:get_all("advanced", "global") or {}
    local rv = {
        enabled        = conf.enabled or "0",
        enable_sysinfo = conf.enable_sysinfo or "0",
        enable_bypass  = conf.enable_bypass or "0",
        enable_natmap  = conf.enable_natmap or "0"
    }
    luci.http.prepare_content("application/json")
    luci.http.write_json(rv)
end

function advanced_sysinfo(value)
    local is_enable = (luci.http.formvalue("value") == "1")
    local uci = require "luci.model.uci".cursor()
    uci:set("advanced", "global", "enable_sysinfo", is_enable and "1" or "0")
    uci:commit("advanced")

    luci.http.prepare_content("application/json")
    
    local PROFILE_PATH = "/etc/profile"
    local SYSINFO_LINE = "/etc/sysinfo"

    if not nixio.fs.access(PROFILE_PATH) then
        luci.http.write_json({ code = 1, error = "Profile file not found." })
        return
    end

    local delete_cmd = string.format("sed -i '/\\/etc\\/sysinfo/d' %q; sed -i '/^$/d' %q", PROFILE_PATH, PROFILE_PATH)
    luci.sys.exec(delete_cmd)
    
    if is_enable then
        local ensure_newline_cmd = "echo >> %q" % PROFILE_PATH
        luci.sys.exec(ensure_newline_cmd)

        local append_cmd = "echo -e '%s\\n' >> %q" %{ SYSINFO_LINE, PROFILE_PATH }
        luci.sys.exec(append_cmd)
        luci.sys.exec("chmod +x /etc/sysinfo 2>/dev/null")
    end

    luci.http.write_json({ code = 0, status = is_enable and "enabled" or "disabled" })
end

function list_response(path, success)
    luci.http.prepare_content("application/json")
    local result
    if success then
        local rv = scandir(path)
        result = {
            ec = 0,
            data = rv
        }
    else
        result = {
            ec = 1
        }
    end
    luci.http.write_json(result)
end

function fileassistant_list()
    local path = luci.http.formvalue("path")
    list_response(path, true)
end

function fileassistant_open()
    local path = luci.http.formvalue("path")
    local filename = luci.http.formvalue("filename")
    local io = require "io"
    local mime = to_mime(filename)

    file = path..filename

    local download_fpi = io.open(file, "r")
    luci.http.header('Content-Disposition', 'inline; filename="'..filename..'"' )
    luci.http.prepare_content(mime)
    luci.ltn12.pump.all(luci.ltn12.source.file(download_fpi), luci.http.write)
end

function fileassistant_delete()
    local path = luci.http.formvalue("path")
    local isdir = luci.http.formvalue("isdir")
    path = path:gsub("<>", "/")
    path = path:gsub(" ", "\ ")
    local success
    if isdir then
        success = os.execute('rm -r "'..path..'"')
    else
        success = os.remove(path)
    end
    list_response(nixio.fs.dirname(path), success)
end

function fileassistant_rename()
    local filepath = luci.http.formvalue("filepath")
    local newpath = luci.http.formvalue("newpath")
    local success = os.execute('mv "'..filepath..'" "'..newpath..'"')
    list_response(nixio.fs.dirname(filepath), success)
end

function fileassistant_install()
    local filepath = luci.http.formvalue("filepath")
    local isdir = luci.http.formvalue("isdir")
    local ext = filepath:match(".+%.(%w+)$")
    filepath = filepath:gsub("<>", "/")
    filepath = filepath:gsub(" ", "\ ")
    local success
    if isdir == "1" then
        success = false  
    elseif ext == "ipk" then
        success = installIPK(filepath)
    else
        success = false
    end
    list_response(nixio.fs.dirname(filepath), success)
end

function installIPK(filepath)
    luci.sys.exec('opkg --force-depends install "'..filepath..'"')
    luci.sys.exec('rm -rf /tmp/luci-*')
    return true;
end

function fileassistant_upload()
    local filecontent = luci.http.formvalue("upload-file")
    local filename = luci.http.formvalue("upload-filename")
    local uploaddir = luci.http.formvalue("upload-dir")
    local filepath = uploaddir..filename

    local fp
    luci.http.setfilehandler(
        function(meta, chunk, eof)
            if not fp and meta and meta.name == "upload-file" then
                fp = io.open(filepath, "w")
            end
            if fp and chunk then
                fp:write(chunk)
            end
            if fp and eof then
                fp:close()
            end
      end
    )

    list_response(uploaddir, true)
end

function scandir(directory)
    local i, t, popen = 0, {}, io.popen

    local pfile = popen("ls -lh \""..directory.."\" | egrep '^d' ; ls -lh \""..directory.."\" | egrep -v '^d|^l'")
    for fileinfo in pfile:lines() do
        i = i + 1
        t[i] = fileinfo
    end
    pfile:close()
    pfile = popen("ls -lh \""..directory.."\" | egrep '^l' ;")
    for fileinfo in pfile:lines() do
        i = i + 1
        linkindex, _, linkpath = string.find(fileinfo, "->%s+(.+)$")
        local finalpath;
        if string.sub(linkpath, 1, 1) == "/" then
            finalpath = linkpath
        else
            finalpath = nixio.fs.realpath(directory..linkpath)
        end
        local linktype;
        if not finalpath then
            finalpath = linkpath;
            linktype = 'x'
        elseif nixio.fs.stat(finalpath, "type") == "dir" then
            linktype = 'z'
        else
            linktype = 'l'
        end
        fileinfo = string.sub(fileinfo, 2, linkindex - 1)
        fileinfo = linktype..fileinfo.."-> "..finalpath
        t[i] = fileinfo
    end
    pfile:close()
    return t
end

MIME_TYPES = {
    ["txt"]   = "text/plain";
    ["conf"]  = "text/plain";
    ["ovpn"]  = "text/plain";
    ["log"]   = "text/plain";
    ["js"]    = "text/javascript";
    ["css"]   = "text/css";
    ["htm"]   = "text/html";
    ["html"]  = "text/html";
    ["patch"] = "text/x-patch";
    ["c"]     = "text/x-csrc";
    ["h"]     = "text/x-chdr";
    ["o"]     = "text/x-object";
    ["ko"]    = "text/x-object";

    ["bmp"]   = "image/bmp";
    ["gif"]   = "image/gif";
    ["png"]   = "image/png";
    ["jpg"]   = "image/jpeg";
    ["jpeg"]  = "image/jpeg";
    ["svg"]   = "image/svg+xml";

    ["json"]  = "application/json";
    ["zip"]   = "application/zip";
    ["pdf"]   = "application/pdf";
    ["xml"]   = "application/xml";
    ["xsl"]   = "application/xml";
    ["doc"]   = "application/msword";
    ["ppt"]   = "application/vnd.ms-powerpoint";
    ["xls"]   = "application/vnd.ms-excel";
    ["odt"]   = "application/vnd.oasis.opendocument.text";
    ["odp"]   = "application/vnd.oasis.opendocument.presentation";
    ["pl"]    = "application/x-perl";
    ["sh"]    = "application/x-shellscript";
    ["php"]   = "application/x-php";
    ["deb"]   = "application/x-deb";
    ["iso"]   = "application/x-cd-image";
    ["tgz"]   = "application/x-compressed-tar";

    ["mp3"]   = "audio/mpeg";
    ["ogg"]   = "audio/x-vorbis+ogg";
    ["wav"]   = "audio/x-wav";

    ["mpg"]   = "video/mpeg";
    ["mpeg"]  = "video/mpeg";
    ["avi"]   = "video/x-msvideo";
}

function to_mime(filename)
    if type(filename) == "string" then
        local ext = filename:match("[^%.]+$")

        if ext and MIME_TYPES[ext:lower()] then
            return MIME_TYPES[ext:lower()]
        end
    end

    return "application/octet-stream"
end

local function format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1073741824 then
        return string.format("%.2f GiB", bytes / 1073741824)
    elseif bytes >= 1048576 then
        return string.format("%.2f MiB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.2f KiB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

function action_guard_data()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local rv = { rules = {}, clients = {} }
    local all_nft = sys.exec("nft -p list table inet bypass_logic 2>/dev/null") or ""

    if all_nft ~= "" then
        local general_aggregator = {}
        local order_tracker = {}
        local blocks = {
            all_nft:match("chain static_privilege%s+{(.-)}"),
            all_nft:match("chain static_privilege_output%s+{(.-)}"),
            all_nft:match("chain dynamic_logic%s+{(.-)}")
        }
        for _, block_content in ipairs(blocks) do
            if block_content then
                for packets, bytes, comment in block_content:gmatch("counter packets (%d+) bytes (%d+).-comment \"(.-)\"") do
                    local key = comment
                    key = key:gsub("%-?[tT][cC][pP]%-?", "-"):gsub("%-?[uU][dD][pP]%-?", "-")
                    key = key:gsub("%-?[vV]?[46]%-?", "-")
                    key = key:gsub("%-+", "-"):gsub("%-+$", ""):gsub("^%-+", "")
                    if not general_aggregator[key] then
                        general_aggregator[key] = { 
                            packets = 0, bytes = 0, 
                            name = key,
                            display_action = "" 
                        }
                        table.insert(order_tracker, key)
                    end

                    general_aggregator[key].packets = general_aggregator[key].packets + tonumber(packets)
                    general_aggregator[key].bytes = general_aggregator[key].bytes + tonumber(bytes)

                    if general_aggregator[key].display_action == "" then
                        local friendly = "—"
                        if key:find("Direct") then
                            if key:find("BT") or key:find("qB") then friendly = translate("Direct / BitTorrent")
                            elseif key:find("CF%-Tunnel") then friendly = translate("Direct / Cloudflare Tunnel")
                            elseif key:find("CN%-Direct") then friendly = translate("Direct / China IP Address")
                            elseif key:find("STUN%-Direct") then friendly = translate("Direct / STUN Penetration")
                            else friendly = translate("Direct / Bypass") end
                        elseif key:find("Global%-Bypass") then friendly = translate("Direct / Global Whitelist")
                        elseif key:find("PASS") then friendly = translate("Proxy / Agent Redirect")
                        elseif key:find("Fix") or key:find("Loopback") then
                            if key:find("Local") then friendly = translate("System / Router Self-Agent Redirect")
                            elseif key:find("Loopback") then friendly = translate("System / Loopback Bypass")
                            else friendly = translate("System / Routing Fix") end
                        end
                        general_aggregator[key].display_action = friendly
                    end
                end
            end
        end

        for _, k in ipairs(order_tracker) do
            local item = general_aggregator[k]
            table.insert(rv.rules, {
                name    = item.name,
                packets = tostring(item.packets),
                bytes   = (type(format_bytes) == "function") and format_bytes(item.bytes) or tostring(item.bytes),
                bytes_raw = item.bytes,
                comment = item.display_action
            })
        end

        local qb_fix_block = all_nft:match("chain qb_fix%s+{(.-)}") or ""
        local nat_aggregator = {}
        local nat_order = {}

        for v_num, proto, dport, packets, bytes, target in qb_fix_block:gmatch("ipv(%d).-%s+([a-z]+)%s+dport%s+(%d+).-counter%s+packets%s+(%d+)%s+bytes%s+(%d+).-to%s+(%S+)") do
            local target_port = target:match(":(%d+)$") or target
            local key = dport .. "_" .. target_port
            if not nat_aggregator[key] then
                nat_aggregator[key] = { dport = dport, target_port = target_port, packets = 0, bytes = 0, protos = {} }
                table.insert(nat_order, key)
            end
            nat_aggregator[key].packets = nat_aggregator[key].packets + tonumber(packets)
            nat_aggregator[key].bytes = nat_aggregator[key].bytes + tonumber(bytes)
            nat_aggregator[key].protos[proto:upper()] = true
        end

        for _, k in ipairs(nat_order) do
            local data = nat_aggregator[k]
            local p_list = {}
            for p in pairs(data.protos) do table.insert(p_list, p) end
            table.sort(p_list)
            table.insert(rv.rules, {
                name    = table.concat(p_list, "/") .. "-Fix: " .. data.dport,
                packets = tostring(data.packets),
                bytes   = (type(format_bytes) == "function") and format_bytes(data.bytes) or tostring(data.bytes),
                bytes_raw = data.bytes,
                comment = translate("NAT / Dual-Stack Forward") .. " -> :" .. data.target_port
            })
        end
    end

    local ip_map = {}
    local mac_map = {}
    uci:foreach("dhcp", "host", function(s)
        if s.name then
            if s.ip then ip_map[s.ip] = s.name end
            if s.mac then
                if type(s.mac) == "table" then
                    for _, m in ipairs(s.mac) do
                        mac_map[m:lower()] = s.name
                    end
                elseif type(s.mac) == "string" then
                    for m in s.mac:gmatch("%S+") do
                        mac_map[m:lower()] = s.name
                    end
                end
            end
        end
    end)

    local function find_hostname(ip)
        if not ip then return nil, nil end
        local name = nil
        local mac = ""
        if ip_map[ip] then
            name = ip_map[ip]
        end
        local mac_out = sys.exec(string.format("ip neigh show %s | awk '{print $5}'", ip)) or ""
        mac = mac_out:gsub("[%s\n]", ""):lower()
        if not name and mac ~= "" and mac_map[mac] then
            name = mac_map[mac]
        end
        if (not mac or mac == "") and name then
            for m, n in pairs(mac_map) do
                if n == name then
                    mac = m:lower()
                    break
                end
            end
        end
        return name, mac
    end

    local function fetch_clients(set_name, is_server_group)
        local raw_set = sys.exec(string.format("nft list set inet bypass_logic %s 2>/dev/null", set_name)) or ""
        local elements = raw_set:match("elements = { (.-) }")
        if elements then
            for single_ip in elements:gmatch("([^, %s]+)") do
                if (single_ip:match("%d+%.%d+") or single_ip:find(":")) 
                    and not single_ip:find("timeout") 
                    and not single_ip:find("expires") then
                    local found = false
                    for _, existing in ipairs(rv.clients) do
                        if existing.ip == single_ip then
                            if is_server_group then existing.is_server = true end
                            found = true
                            break
                        end
                    end

                    if not found then
                        local name, mac = find_hostname(single_ip)
                        table.insert(rv.clients, {
                            ip        = single_ip,
                            mac       = (mac and mac ~= "") and mac:upper() or "—",
                            hostname  = name or "Configured-Device",
                            is_server = is_server_group
                        })
                    end
                end
            end
        end
    end

    fetch_clients("psw_vpn_clients", false)
    fetch_clients("psw_vpn_clients6", false)
    fetch_clients("quic_direct_clients", true)
    fetch_clients("quic_direct_clients6", true)

    luci.http.prepare_content("application/json")
    luci.http.write_json(rv)
end

function action_guard_status()
    local set = luci.http.formvalue("set")
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    
    if set == "enable" then
        uci:set("advanced", "global", "enable_bypass", "1")
        uci:commit("advanced")
        sys.exec("/etc/init.d/bypass_guard enable")
        sys.exec("/etc/init.d/bypass_guard start")
    elseif set == "disable" then
        uci:set("advanced", "global", "enable_bypass", "0")
        uci:commit("advanced")
        sys.exec("/etc/init.d/bypass_guard stop")
        sys.exec("/etc/init.d/bypass_guard disable")
    end
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({ code = 0 })
end

function action_set_natmap()
    local set = luci.http.formvalue("set")
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local script_path = "/usr/share/bypass_guard/scripts/natmap_bypass.sh"
    uci:set("advanced", "global", "enable_natmap", set)
    uci:commit("advanced")

    uci:foreach("natmap", "natmap", function(s)
        if s.comment == "qBittorrent" then
            local sid = s[".name"]
            if set == "1" then
                uci:set("natmap", sid, "custom_script", script_path)
            else
                uci:set("natmap", sid, "custom_script", "")
            end
        end
    end)
    uci:commit("natmap")
    sys.exec("/etc/init.d/natmap reload")
    
    local running = (sys.call("/etc/init.d/bypass_guard status >/dev/null 2>&1") == 0)
    if running then
        sys.exec("/etc/init.d/bypass_guard reload")
    end
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({ code = 0 })
end

function index()
    local nixio = require "nixio"
    local translate = luci.i18n.translate
    local entry = luci.dispatcher.entry
    local cbi = luci.dispatcher.cbi
    local call = luci.dispatcher.call
    if not nixio.fs.access("/etc/config/advanced")then
        return
    end
    local e
    e=entry({"admin","system","advanced"},cbi("advanced"),translate("Advanced Function"),60)
    e.dependent=true

    entry({"admin", "system", "advanced", "sysinfo"}, call("advanced_sysinfo"), nil).leaf = true

    local fa_base = entry({"admin", "system", "advanced", "fileassistant"}, nil, nil)
    fa_base.i18n = "base"

    entry({"admin", "system", "advanced", "fileassistant", "list"}, call("fileassistant_list"), nil).leaf = true
    entry({"admin", "system", "advanced", "fileassistant", "open"}, call("fileassistant_open"), nil).leaf = true
    entry({"admin", "system", "advanced", "fileassistant", "delete"}, call("fileassistant_delete"), nil).leaf = true
    entry({"admin", "system", "advanced", "fileassistant", "rename"}, call("fileassistant_rename"), nil).leaf = true
    entry({"admin", "system", "advanced", "fileassistant", "upload"}, call("fileassistant_upload"), nil).leaf = true
    entry({"admin", "system", "advanced", "fileassistant", "install"}, call("fileassistant_install"), nil).leaf = true

    entry({"admin", "system", "advanced", "guard_data"}, call("action_guard_data"), nil).leaf = true
    entry({"admin", "system", "advanced", "guard_status"}, call("action_guard_status"), nil).leaf = true
    entry({"admin", "system", "advanced", "get_guard_config"}, call("action_get_config"), nil).leaf = true
    entry({"admin", "system", "advanced", "set_natmap"}, call("action_set_natmap"), nil).leaf = true
end
