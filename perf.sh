#!/bin/sh
# 用法:
#  采样单个线程: ./perf-flame.sh [-e EVENT] <TID> [ALIAS]
#  按线程号采样: ./perf-flame.sh [-e EVENT] -t <N> [PATTERN]  # 别名自动为 T<N>
#  生成差分火焰图: ./perf-flame.sh -d <基线.folded> <新.folded>
#
# 采样后立即折叠保存为 .folded (符号已解析), 不保留原始 .data,
# 这样即使之后模块重载/机器重启, 也能正常生成 diff 火焰图
#
# 默认采样事件
DEFAULT_EVENT="cpu-clock"

# 显示帮助信息
show_usage() {
    echo "用法:"
    echo "  采样并生成火焰图: $0 [-e EVENT] <TID> [ALIAS]"
    echo "  按线程号采样:     $0 [-e EVENT] -t <N> [PATTERN]"
    echo "  生成差分火焰图:   $0 -d <baseline.folded> <latest.folded>"
    echo ""
    echo "选项:"
    echo "  -e, --event EVENT   指定 perf 采样事件 (默认: $DEFAULT_EVENT)"
    echo "                      例: cpu-clock, cycles, cache-misses, sched:sched_switch"
    echo "  -t, --thread N      指定线程号 N, 自动查找线程名完全等于 <PATTERN>/N 的线程"
    echo "                      (如 PROTO_IO/3, 不会匹配 DUPROTO_IO/3), 获取其 TID 进行采样,"
    echo "                      别名自动设为 T<N>"
    echo "                      PATTERN 可选, 默认: PROTO_IO"
    echo ""
    echo "Examples:"
    echo "  $0 216164                  # 采样线程216164"
    echo "  $0 216164 io-thread        # 采样线程216164, 别名 io-thread"
    echo "  $0 -e cycles 216164        # 使用 cycles 事件采样"
    echo "  $0 -t 3                    # 查找 PROTO_IO/3 线程并采样, 别名 T3"
    echo "  $0 -t 3 WORKER             # 查找 WORKER.../3 线程并采样, 别名 T3"
    echo "  $0 -e cache-misses -t 5    # 使用 cache-misses 事件采样线程号5"
    echo "  $0 -d perf-io-thread.folded perf-io-thread.folded # 对比时自动识别别名"
    echo ""
    echo "  ALIAS: 给线程起个别名, 方便在对比时识别 (不保存)"
    echo "  查看可用事件: perf list"
    exit 1
}

# 按线程号查找 TID: 线程名必须完全等于 PATTERN/N (如 PROTO_IO/3, 不匹配 DUPROTO_IO/3), 且 rss > 0
# 匹配不到或匹配到多个时报错并列出候选线程
resolve_thread() {
    N=$1
    PATTERN=$2

    # 全字符匹配: comm 必须严格等于 "PATTERN/N"
    LINE=$(ps -eLo tid,pid,psr,comm,rss | awk -v pat="$PATTERN" -v n="$N" \
        '$5 > 0 && $4 == (pat "/" n)')

    COUNT=$(echo "$LINE" | grep -c .)

    if [ "$COUNT" -eq 0 ]; then
        echo "Error: 未找到线程号为 $N 的线程 (pattern: $PATTERN, 要求线程名完全等于 $PATTERN/$N)"
        echo "当前可用线程:"
        ps -eLo tid,pid,psr,comm,rss | awk -v pat="$PATTERN" \
            '$5 > 0 && index($4, pat "/") == 1 {print $4}' | sort -u
        exit 1
    fi

    if [ "$COUNT" -gt 1 ]; then
        echo "Error: 线程号 $N 匹配到多个线程 (pattern: $PATTERN), 请指定更精确的 PATTERN:"
        echo "$LINE"
        exit 1
    fi

    echo "$LINE" | awk '{print $1}'
}

# 生成差分火焰图: 输入为两个已折叠的 .folded 文件
gen_diff() {
    BASELINE=$1
    LATEST=$2

    # .folded 必须存在且非空 (空文件会让 difffolded.pl -n 除以零崩溃)
    for f in "$BASELINE" "$LATEST"; do
        if [ ! -s "$f" ]; then
            echo "Error: folded file not found or empty: $f"
            exit 1
        fi
    done

    echo "Generating diff flame graph..."
    echo "  Baseline: $BASELINE"
    echo "  Latest:   $LATEST"

    # 从文件名中提取前缀（别名或TID），去掉时间戳部分
    BASELINE_PREFIX=$(basename "$BASELINE" .folded | sed 's/perf-//' | sed 's/-[0-9]\{8\}_[0-9]\{6\}$//')
    LATEST_PREFIX=$(basename "$LATEST" .folded | sed 's/perf-//' | sed 's/-[0-9]\{8\}_[0-9]\{6\}$//')

    # 提取时间戳
    BASELINE_TS=$(echo "$BASELINE" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)
    LATEST_TS=$(echo "$LATEST" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | head -1)

    # 确定前缀
    if [ "$BASELINE_PREFIX" = "$LATEST_PREFIX" ]; then
        PREFIX="$BASELINE_PREFIX"
    else
        PREFIX="${BASELINE_PREFIX}-vs-${LATEST_PREFIX}"
    fi

    # 生成时间戳范围（如果都能提取到）
    if [ -n "$BASELINE_TS" ] && [ -n "$LATEST_TS" ]; then
        TIMESTAMP_RANGE="${BASELINE_TS}-vs-${LATEST_TS}"
    else
        TIMESTAMP_RANGE=$(date +%Y%m%d_%H%M%S)
    fi

    # 输出文件名: perf-(alias)-diff-(时间戳范围).svg
    OUTPUT="perf-${PREFIX}-diff-${TIMESTAMP_RANGE}.svg"

    echo "Output file: $OUTPUT"

    # 直接对折叠文件做差分
    # -n: 把 baseline 的样本数按 (latest 总数 / baseline 总数) 归一化,
    #     这样比较的是"占比变化"而不是绝对样本数变化 (两次采样总量常常不同)
    ./FlameGraph/difffolded.pl -n "$BASELINE" "$LATEST" | \
        ./FlameGraph/flamegraph.pl > "$OUTPUT"

    echo "✅ Diff flame graph generated: $OUTPUT"
    echo "  宽度 = latest 的样本数 (不是 delta), 颜色 = latest - baseline (已归一化)"
    echo "  Red = increased, Blue = decreased, White = unchanged"
    echo "  颜色只反映该帧作为叶子(自身耗时)的样本变化, 不含子调用"
}

# 采样并生成火焰图
gen_normal() {
    TID=$1
    ALIAS=$2
    EVENT=$3

    # 未指定事件时使用默认值
    if [ -z "$EVENT" ]; then
        EVENT="$DEFAULT_EVENT"
    fi

    # 确定前缀: 有别名用别名, 否则用 t-TID
    if [ -n "$ALIAS" ]; then
        PREFIX="$ALIAS"
        echo "Sampling TID: $TID (alias: $ALIAS)"
    else
        PREFIX="t${TID}"
        echo "Sampling TID: $TID"
    fi
    echo "Event: $EVENT"

    TS=$(date +%Y%m%d_%H%M%S)
    DATA_FILE="perf-${PREFIX}-${TS}.data"
    FOLDED_FILE="perf-${PREFIX}-${TS}.folded"

    # 采样
    perf record -o "$DATA_FILE" -e "$EVENT" --proc-map-timeout 10 -g -t "$TID" sleep 10
    if [ $? -ne 0 ]; then
        echo "Error: perf record failed"
        exit 1
    fi

    # 立即解析并折叠: 符号在当前系统状态下解析, 之后模块重载/重启不影响 diff
    echo "Folding stacks..."
    perf script -i "$DATA_FILE" | ./FlameGraph/stackcollapse-perf.pl > "$FOLDED_FILE"
    if [ ! -s "$FOLDED_FILE" ]; then
        echo "Error: 折叠结果为空 (线程可能空闲, 未采到样本), 保留原始数据: $DATA_FILE"
        rm -f "$FOLDED_FILE"
        exit 1
    fi

    # 折叠成功后不再保留原始 data
    rm -f "$DATA_FILE"

    echo "Generating flame graph..."

    # 生成火焰图
    ./FlameGraph/flamegraph.pl < "$FOLDED_FILE" > "perf-${PREFIX}-${TS}.svg"

    echo "🔥 Flame graph generated: perf-${PREFIX}-${TS}.svg"
    echo "  Folded file saved: $FOLDED_FILE"
}

# 主逻辑
EVENT="$DEFAULT_EVENT"
THREAD_NO=""
THREAD_PATTERN="PROTO_IO"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--diff)
            if [ $# -ne 3 ]; then
                echo "Error: -d requires two .folded files"
                show_usage
            fi
            gen_diff "$2" "$3"
            exit 0
            ;;
        -t|--thread)
            if [ $# -lt 2 ]; then
                echo "Error: -t requires a thread number"
                show_usage
            fi
            case "$2" in
                ''|*[!0-9]*)
                    echo "Error: 线程号必须是数字: $2"
                    show_usage
                    ;;
            esac
            THREAD_NO="$2"
            shift 2
            # 可选 PATTERN: 仅当下一个参数不是选项时才消费, 保证 -t 5 -e cycles 也能正确解析
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                THREAD_PATTERN="$1"
                shift
            fi
            ;;
        -e|--event)
            if [ $# -lt 2 ]; then
                echo "Error: -e requires an event name"
                show_usage
            fi
            EVENT="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: Unknown option: $1"
            show_usage
            ;;
        *)
            break
            ;;
    esac
done

# 按线程号模式: 查找 TID 后采样, 别名 T<N>
if [ -n "$THREAD_NO" ]; then
    TID=$(resolve_thread "$THREAD_NO" "$THREAD_PATTERN")
    gen_normal "$TID" "T${THREAD_NO}" "$EVENT"
    exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    show_usage
fi
gen_normal "$1" "$2" "$EVENT"