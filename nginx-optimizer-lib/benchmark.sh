#!/bin/bash

################################################################################
# benchmark.sh - Performance Benchmarking Functions
################################################################################

BENCHMARK_RESULTS_DIR="${DATA_DIR}/benchmarks"

################################################################################
# Benchmark Functions
################################################################################

run_benchmark() {
    local target_site="$1"

    if [ -z "$target_site" ]; then
        log_error "Site parameter required for benchmarking"
        exit 1
    fi

    mkdir -p "$BENCHMARK_RESULTS_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local results_file="${BENCHMARK_RESULTS_DIR}/${target_site}-${timestamp}.txt"
    local url="https://$target_site"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Performance Benchmark: $target_site"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    log_info "Running comprehensive performance benchmarks..."
    log_info "Results will be saved to: $results_file"

    {
        echo "Performance Benchmark Results"
        echo "=============================="
        echo "Site: $target_site"
        echo "URL: $url"
        echo "Date: $(date)"
        echo ""
    } | tee "$results_file"

    # 1. Response Time Test
    benchmark_response_time "$url" | tee -a "$results_file"

    # 2. Page Load Test
    benchmark_page_load "$url" | tee -a "$results_file"

    # 3. Concurrent Requests Test
    benchmark_concurrent "$url" | tee -a "$results_file"

    # 4. Cache Performance Test
    benchmark_cache_performance "$url" | tee -a "$results_file"

    # 5. Compression Test
    benchmark_compression "$url" | tee -a "$results_file"

    # 6. TTFB (Time To First Byte) Test
    benchmark_ttfb "$url" | tee -a "$results_file"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    log_success "Benchmark complete!"
    log_info "Full results: $results_file"
    echo ""

    # Show summary
    show_benchmark_summary "$results_file"
}

benchmark_response_time() {
    local url="$1"

    echo ""
    echo "1. Response Time Test (10 requests)"
    echo "───────────────────────────────────"

    local total=0
    local count=10

    for i in $(seq 1 $count); do
        local time
        time=$(curl -o /dev/null -s -w "%{time_total}" "$url")
        total=$(echo "$total + $time" | bc)
        echo "  Request $i: ${time}s"
    done

    local avg
    avg=$(echo "scale=3; $total / $count" | bc)
    echo ""
    echo "  Average: ${avg}s"
    echo ""
}

benchmark_page_load() {
    local url="$1"

    echo ""
    echo "2. Page Load Time Breakdown"
    echo "───────────────────────────────────"

    local metrics
    metrics=$(curl -o /dev/null -s -w "DNS: %{time_namelookup}s\nConnect: %{time_connect}s\nSSL: %{time_appconnect}s\nTTFB: %{time_starttransfer}s\nTotal: %{time_total}s\n" "$url")

    echo "$metrics" | sed 's/^/  /'
    echo ""
}

benchmark_concurrent() {
    local url="$1"
    local concurrent=10
    local total_requests=100

    echo ""
    echo "3. Concurrent Requests Test"
    echo "───────────────────────────────────"
    echo "  Concurrent: $concurrent"
    echo "  Total Requests: $total_requests"
    echo ""

    # Use ab if available
    if command -v ab &>/dev/null; then
        log_info "Using ApacheBench (ab)..."
        ab -n $total_requests -c $concurrent -q "$url" 2>&1 | grep -E "Requests per second|Time per request|Transfer rate" | sed 's/^/  /'
    else
        log_warn "ApacheBench (ab) not installed, skipping concurrent test"
        echo "  Install with: brew install httpd (macOS) or apt install apache2-utils (Linux)"
    fi

    echo ""
}

benchmark_cache_performance() {
    local url="$1"

    echo ""
    echo "4. Cache Performance Test"
    echo "───────────────────────────────────"

    # Cold cache
    log_info "Cold cache (first request)..."
    local cold_time
    cold_time=$(curl -o /dev/null -s -w "%{time_total}" "$url")
    local cold_cache
    cold_cache=$(curl -sI "$url" | grep -i "x-fastcgi-cache:" | awk '{print $2}')
    echo "  Time: ${cold_time}s"
    echo "  Status: ${cold_cache:-N/A}"

    # Warm cache
    sleep 1
    log_info "Warm cache (second request)..."
    local warm_time
    warm_time=$(curl -o /dev/null -s -w "%{time_total}" "$url")
    local warm_cache
    warm_cache=$(curl -sI "$url" | grep -i "x-fastcgi-cache:" | awk '{print $2}')
    echo "  Time: ${warm_time}s"
    echo "  Status: ${warm_cache:-N/A}"

    # Calculate improvement
    if command -v bc &>/dev/null; then
        local improvement
        improvement=$(echo "scale=2; (($cold_time - $warm_time) / $cold_time) * 100" | bc)
        echo ""
        echo "  Cache improvement: ${improvement}%"
    fi

    echo ""
}

benchmark_compression() {
    local url="$1"

    echo ""
    echo "5. Compression Test"
    echo "───────────────────────────────────"

    # Test without compression
    log_info "Without compression..."
    local size_uncompressed
    size_uncompressed=$(curl -s -H "Accept-Encoding: identity" "$url" | wc -c)
    echo "  Size: $size_uncompressed bytes"

    # Test with gzip
    log_info "With gzip..."
    local size_gzip
    size_gzip=$(curl -s -H "Accept-Encoding: gzip" "$url" | wc -c)
    local encoding_gzip
    encoding_gzip=$(curl -sI -H "Accept-Encoding: gzip" "$url" | grep -i "content-encoding:" | awk '{print $2}')
    echo "  Size: $size_gzip bytes"
    echo "  Encoding: ${encoding_gzip:-none}"

    # Test with brotli
    log_info "With brotli..."
    local size_brotli
    size_brotli=$(curl -s -H "Accept-Encoding: br" "$url" | wc -c)
    local encoding_brotli
    encoding_brotli=$(curl -sI -H "Accept-Encoding: br" "$url" | grep -i "content-encoding:" | awk '{print $2}')
    echo "  Size: $size_brotli bytes"
    echo "  Encoding: ${encoding_brotli:-none}"

    # Calculate compression ratios
    if command -v bc &>/dev/null && [ "$size_uncompressed" -gt 0 ]; then
        local ratio_gzip
        ratio_gzip=$(echo "scale=2; (($size_uncompressed - $size_gzip) / $size_uncompressed) * 100" | bc)
        local ratio_brotli
        ratio_brotli=$(echo "scale=2; (($size_uncompressed - $size_brotli) / $size_uncompressed) * 100" | bc)

        echo ""
        echo "  Gzip compression: ${ratio_gzip}%"
        echo "  Brotli compression: ${ratio_brotli}%"
    fi

    echo ""
}

benchmark_ttfb() {
    local url="$1"

    echo ""
    echo "6. Time To First Byte (TTFB)"
    echo "───────────────────────────────────"

    local count=5
    local total=0

    for i in $(seq 1 $count); do
        local ttfb
        ttfb=$(curl -o /dev/null -s -w "%{time_starttransfer}" "$url")
        total=$(echo "$total + $ttfb" | bc)
        echo "  Test $i: ${ttfb}s"
    done

    local avg
    avg=$(echo "scale=3; $total / $count" | bc)
    echo ""
    echo "  Average TTFB: ${avg}s"

    # Rating
    if command -v bc &>/dev/null; then
        if awk -v avg="$avg" 'BEGIN { exit !(avg < 0.2) }'; then
            echo "  Rating: Excellent (< 0.2s)"
        elif awk -v avg="$avg" 'BEGIN { exit !(avg < 0.5) }'; then
            echo "  Rating: Good (< 0.5s)"
        elif awk -v avg="$avg" 'BEGIN { exit !(avg < 1.0) }'; then
            echo "  Rating: Fair (< 1.0s)"
        else
            echo "  Rating: Needs Improvement (> 1.0s)"
        fi
    fi

    echo ""
}

show_benchmark_summary() {
    local results_file="$1"

    echo "Summary"
    echo "═══════"
    echo ""

    # Extract key metrics
    local avg_response
    avg_response=$(grep "Average:" "$results_file" | head -1 | awk '{print $2}')
    local avg_ttfb
    avg_ttfb=$(grep "Average TTFB:" "$results_file" | awk '{print $3}')
    local cache_status
    cache_status=$(grep "Warm cache" -A2 "$results_file" | grep "Status:" | awk '{print $2}')

    echo "  Average Response Time: ${avg_response:-N/A}"
    echo "  Average TTFB: ${avg_ttfb:-N/A}"
    echo "  Cache Status: ${cache_status:-N/A}"

    echo ""
}

compare_benchmarks() {
    local site="$1"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Benchmark Comparison: $site"
    echo "═══════════════════════════════════════════════════════════"

    local -a benchmarks=()
    while IFS= read -r file; do
        benchmarks+=("$file")
    done < <(ls -t "${BENCHMARK_RESULTS_DIR}/${site}-"*.txt 2>/dev/null | head -2)

    if [ ${#benchmarks[@]} -lt 2 ]; then
        log_info "Need at least 2 benchmarks to compare"
        log_info "Current benchmarks: ${#benchmarks[@]}"
        return
    fi

    local latest="${benchmarks[0]}"
    local previous="${benchmarks[1]}"

    echo ""
    echo "Latest:   $(basename "$latest")"
    echo "Previous: $(basename "$previous")"
    echo ""

    # Compare key metrics
    echo "Metric Comparison:"
    echo "──────────────────"

    local latest_resp
    latest_resp=$(grep "Average:" "$latest" | head -1 | awk '{print $2}' | tr -d 's')
    local prev_resp
    prev_resp=$(grep "Average:" "$previous" | head -1 | awk '{print $2}' | tr -d 's')

    if [ -n "$latest_resp" ] && [ -n "$prev_resp" ]; then
        local diff
        diff=$(echo "scale=3; $latest_resp - $prev_resp" | bc)
        local pct
        pct=$(echo "scale=2; ($diff / $prev_resp) * 100" | bc)

        echo "  Response Time:"
        echo "    Latest: ${latest_resp}s"
        echo "    Previous: ${prev_resp}s"
        echo "    Change: ${diff}s (${pct}%)"

        if awk -v diff="$diff" 'BEGIN { exit !(diff < 0) }'; then
            echo -e "    ${GREEN}✓ Improved!${NC}"
        else
            echo -e "    ${YELLOW}⚠ Slower${NC}"
        fi
    fi

    echo ""
}

list_benchmarks() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Available Benchmarks:"
    echo "═══════════════════════════════════════════════════════════"

    if [ ! -d "$BENCHMARK_RESULTS_DIR" ] || [ -z "$(ls -A "$BENCHMARK_RESULTS_DIR" 2>/dev/null)" ]; then
        echo "  No benchmarks found"
        echo ""
        return
    fi

    while IFS= read -r result; do
        [ -f "$result" ] || continue
        local filename
        filename=$(basename "$result")
        local size
        size=$(du -h "$result" | cut -f1)
        local date
        date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$result" 2>/dev/null || stat -c "%y" "$result" 2>/dev/null | cut -d'.' -f1)

        echo "  $filename"
        echo "    Date: $date"
        echo "    Size: $size"
        echo ""
    done < <(ls -t "$BENCHMARK_RESULTS_DIR"/*.txt 2>/dev/null)

    echo "═══════════════════════════════════════════════════════════"
}
