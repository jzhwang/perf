#!/bin/sh
# 用法:
#  采样单个线程: ./perf-flame.sh [-e EVENT] <TID> [ALIAS]
#  生成差分火焰图: ./perf-flame.sh -d <基线.data> <新.data>
#
# 默认采样事件
DEFAULT_EVENT="cpu-clock"

# 显示帮助信息
show_usage() {
    echo "用法:"
    echo "  采样并生成火焰图: $0 [-e EVENT] <TID> [ALIAS]"
    echo "  生成差分火焰图:   $0 -d <baseline.data> <latest.data>"
    echo ""
    echo "选项:"
    echo "  -e, --event EVENT   指定 perf 采样事件 (默认: $DEFAULT_EVENT)"
    echo "                      例: cpu-clock, cycles, cache-misses, sched:sched_switch"
    echo ""
    echo "Examples:"
    echo "  $0 216164                  # 采样线程216164"
    echo "  $0 216164 io-thread        # 采样线程216164, 别名 io-thread"
    echo "  $0 -e cycles 216164        # 使用 cycles 事件采样"
    echo "  $0 -e cache-misses 216164 io-thread"
    echo "  $0 -d perf-io-thread.data perf-io-thread.data # 对比时自动识别别名"
    echo ""
    echo "  ALIAS: 给线程起个别名, 方便在对比时识别 (不保存)"
    echo "  查看可用事件: perf list"
    exit 1
}

# 生成差分火焰图
gen_diff() {
    BASELINE=$1
    LATEST=$2

    if [ ! -f "$BASELINE" ]; then
        echo "Error: Baseline file not found: $BASELINE"
        exit 1
    fi
    if [ ! -f "$LATEST" ]; then
        echo "Error: Latest file not found: $LATEST"
        exit 1
    fi

    echo "Generating diff flame graph..."
    echo "  Baseline: $BASELINE"
    echo "  Latest:   $LATEST"

    # 从文件名中提取前缀（别名或TID），去掉时间戳部分
    BASELINE_PREFIX=$(basename "$BASELINE" .data | sed 's/perf-//' | sed 's/-[0-9]\{8\}_[0-9]\{6\}$//')
    LATEST_PREFIX=$(basename "$LATEST" .data | sed 's/perf-//' | sed 's/-[0-9]\{8\}_[0-9]\{6\}$//')

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

    # 解析并折叠
    perf script -i "$BASELINE" | ./FlameGraph/stackcollapse-perf.pl > /tmp/baseline.folded
    perf script -i "$LATEST" | ./FlameGraph/stackcollapse-perf.pl > /tmp/latest.folded

    # 生成差分火焰图
    ./FlameGraph/difffolded.pl /tmp/baseline.folded /tmp/latest.folded | \
        ./FlameGraph/flamegraph.pl > "$OUTPUT"

    # 清理临时文件
    rm -f /tmp/baseline.folded /tmp/latest.folded

    echo "✅ Diff flame graph generated: $OUTPUT"
    echo "  Red = increased, Blue = decreased"
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

    # 采样
    perf record -o "$DATA_FILE" -e "$EVENT" --proc-map-timeout 10 -g -t "$TID" sleep 10
    if [ $? -ne 0 ]; then
        echo "Error: perf record failed"
        exit 1
    fi

    echo "Generating flame graph..."

    # 生成火焰图
    perf script -i "$DATA_FILE" | \
        ./FlameGraph/stackcollapse-perf.pl | \
        ./FlameGraph/flamegraph.pl > "perf-${PREFIX}-${TS}.svg"

    echo "🔥 Flame graph generated: perf-${PREFIX}-${TS}.svg"
    echo "  Data file saved: $DATA_FILE"
}

# 主逻辑
EVENT="$DEFAULT_EVENT"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--diff)
            if [ $# -ne 3 ]; then
                echo "Error: -d requires two .data files"
                show_usage
            fi
            gen_diff "$2" "$3"
            exit 0
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

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    show_usage
fi
gen_normal "$1" "$2" "$EVENT"