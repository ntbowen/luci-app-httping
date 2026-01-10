#!/bin/sh

DB_PATH=$(uci -q get httping.global.db_path) || DB_PATH="/etc/httping_data.db"

# 初始化数据库 (init.d 中也会做迁移，这里保留基本的创建)
if [ ! -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" "CREATE TABLE monitor_log (id INTEGER PRIMARY KEY AUTOINCREMENT, server_name TEXT, timestamp INTEGER, duration REAL, type TEXT DEFAULT 'httping');"
    sqlite3 "$DB_PATH" "CREATE INDEX idx_ts ON monitor_log(timestamp);"
    sqlite3 "$DB_PATH" "CREATE INDEX idx_name ON monitor_log(server_name);"
    sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL;"
fi

get_uptime_ms() {
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
}

check_server() {
    local section="$1"
    local enabled
    local name
    local url
    local interval
    local type
    
    config_get enabled "$section" "enabled" "0"
    config_get name "$section" "name"
    config_get url "$section" "url"
    config_get interval "$section" "interval" "60"
    config_get type "$section" "type" "httping"

    if [ "$enabled" = "1" ] && [ -n "$url" ]; then
        LAST_RUN_FILE="/tmp/httping_${section}.last"
        NOW=$(date +%s)
        LAST_RUN=0
        [ -f "$LAST_RUN_FILE" ] && LAST_RUN=$(cat "$LAST_RUN_FILE")

        if [ $((NOW - LAST_RUN)) -ge "$interval" ]; then
            echo "$NOW" > "$LAST_RUN_FILE"
            
            (
                TS=$(date +%s)
                DURATION=""
                RETCODE=1

                if [ "$type" = "tcping" ]; then
                    # TCPing 处理逻辑 - 纯 Lua 实现 (高精度，微秒级)
                    # 支持 IPv6 格式: [2001:db8::1]:80 或 host:port
                    if echo "$url" | grep -q "\["; then
                        HOST=$(echo "$url" | sed -n 's/.*\[\(.*\)\].*/\1/p')
                        PORT=$(echo "$url" | sed -n 's/.*\]:\(.*\)/\1/p')
                    else
                        HOST=$(echo "$url" | cut -d: -f1)
                        PORT=$(echo "$url" | cut -d: -f2)
                    fi
                    
                    if [ -z "$PORT" ] || [ "$HOST" = "$PORT" ]; then PORT=80; fi
                    
                    # 使用 Lua 进行高精度测速 (依赖系统自带的 nixio 库)
                    # 返回结果: "OK 45.123" 或 "FAIL"
                    LUA_SCRIPT="
                    local nixio = require 'nixio'
                    local host = '$HOST'
                    local port = '$PORT'
                    
                    local sock, err
                    -- 1. 解析地址 (支持 IPv4/IPv6)
                    local addr_iter = nixio.getaddrinfo(host, 'inet') or nixio.getaddrinfo(host, 'inet6')
                    if not addr_iter then
                        addr_iter = nixio.getaddrinfo(host) -- 尝试自动
                    end

                    if not addr_iter or not addr_iter[1] then
                        print('FAIL')
                        return
                    end
                    
                    local target = addr_iter[1]
                    target.port = tonumber(port)

                    -- 2. 创建 Socket
                    sock = nixio.socket(target.family, nixio.SOCK_STREAM)
                    if not sock then print('FAIL'); return end
                    
                    sock:setblocking(false) -- 非阻塞模式
                    
                    -- 3. 开始计时
                    local t1_sec, t1_usec = nixio.gettimeofday()
                    
                    -- 4. 发起连接
                    local status, code, msg = sock:connect(target.address, target.port)
                    
                    -- 5. 等待连接 (select)
                    if status ~= true then
                        -- 如果不是立即连接成功，需要 poll 状态
                        if code == nixio.EINPROGRESS then
                            local revents = nixio.poll({ {fd=sock, events=nixio.POLLOUT} }, 2000) -- 2秒超时
                            if not revents or revents == 0 then
                                print('FAIL') -- 超时
                                sock:close()
                                return
                            end
                            
                            -- 再次检查错误状态
                            local err_code = sock:getsockopt('socket', 'error')
                            if err_code ~= 0 then
                                print('FAIL')
                                sock:close()
                                return
                            end
                        else
                            print('FAIL')
                            sock:close()
                            return
                        end
                    end
                    
                    -- 6. 结束计时
                    local t2_sec, t2_usec = nixio.gettimeofday()
                    sock:close()
                    
                    -- 计算差值 (毫秒)
                    local ms = (t2_sec - t1_sec) * 1000 + (t2_usec - t1_usec) / 1000
                    print(string.format('OK %.3f', ms))
                    "
                    
                    RESULT=$(lua -l nixio -e "$LUA_SCRIPT")
                    
                    if echo "$RESULT" | grep -q "^OK"; then
                        DURATION=$(echo "$RESULT" | awk '{print $2}')
                        RETCODE=0
                    else
                        RETCODE=1
                    fi
                else
                    # HTTPing 处理逻辑 (原有逻辑)
                    RESULT=$(curl -L -k -s -o /dev/null -w "%{time_namelookup} %{time_total}" --max-time 5 "$url")
                    RETCODE=$?

                    if [ $RETCODE -eq 0 ]; then
                        T_DNS=$(echo "$RESULT" | awk '{print $1}')
                        T_TOTAL=$(echo "$RESULT" | awk '{print $2}')
                        DURATION=$(awk "BEGIN {print ($T_TOTAL - $T_DNS) * 1000}")
                    fi
                fi

                # 写入数据库
                if [ $RETCODE -eq 0 ] && [ -n "$DURATION" ]; then
                    sqlite3 "$DB_PATH" "INSERT INTO monitor_log (server_name, timestamp, duration, type) VALUES ('$name', $TS, $DURATION, '$type');"
                else
                    sqlite3 "$DB_PATH" "INSERT INTO monitor_log (server_name, timestamp, duration, type) VALUES ('$name', $TS, NULL, '$type');"
                fi
            ) &
        fi
    fi
}

while true; do
    ENABLED=$(uci -q get httping.global.enabled)
    if [ "$ENABLED" != "1" ]; then
        sleep 10
        continue
    fi

    # 加载 OpenWrt 函数库
    . /lib/functions.sh
    
    # 读取配置文件
    config_load "httping"
    
    # 遍历 server 节点
    config_foreach check_server "server"

    sleep 1
done
