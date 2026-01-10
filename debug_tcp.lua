local nixio = require "nixio"
-- 你可以在这里修改测试的目标
local host = "www.baidu.com" 
local port = 80

print("--- 1. DNS Resolve ---")
local addr_iter = nixio.getaddrinfo(host)
if not addr_iter or not addr_iter[1] then print("FAIL: DNS Resolve Error") return end
local addr = addr_iter[1].address
print("Resolved IP: " .. tostring(addr))

print("--- 2. Command Construction ---")
local socat_cmd
-- 构造命令，使用 -d -d 参数增加调试详细度，且不屏蔽错误输出
if string.find(addr, ":") then
    socat_cmd = string.format("socat -d -d -u OPEN:/dev/null TCP6:[%s]:%d,connect-timeout=2", addr, port)
else
    socat_cmd = string.format("socat -d -d -u OPEN:/dev/null TCP4:%s:%d,connect-timeout=2", addr, port)
end
print("Command: " .. socat_cmd)

print("--- 3. Execution ---")
local t1_sec, t1_usec = nixio.gettimeofday()
-- 执行命令并打印返回值
-- Lua 5.1 (OpenWrt) os.execute 通常只返回一个数字 (status code)
-- Lua 5.2+ / LuaJIT 返回 (boolean, string, number)
local ret1, ret2, ret3 = os.execute(socat_cmd)
local t2_sec, t2_usec = nixio.gettimeofday()

print("--- 4. Results ---")
print("os.execute raw returns:", tostring(ret1), tostring(ret2), tostring(ret3))

-- 尝试解析返回值
local success = false
if type(ret1) == "boolean" then
    -- Lua 5.2+ / LuaJIT 风格: true, "exit", 0
    success = ret1
    if not success then print("Fail reason:", ret2, ret3) end
elseif type(ret1) == "number" then
    -- Lua 5.1 标准风格: 返回状态码
    -- 注意：在某些 shell 中，exit code 0 代表成功。
    -- os.execute 返回值通常是 (exit_code << 8) + signal
    -- 所以 0 还是 0。如果返回 256，则代表 exit code 1。
    print("Return code (number):", ret1)
    if ret1 == 0 then success = true end
end

if success then
    local ms = (t2_sec - t1_sec) * 1000 + (t2_usec - t1_usec) / 1000
    print(string.format("SUCCESS! Time: %.3f ms", ms))
else
    print("FAILED! socat exit with error.")
end
