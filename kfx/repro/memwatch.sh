#!/bin/sh
# Sample RSS of a process tree root every INTERVAL seconds until it exits.
# usage: memwatch.sh <pid> <out.csv> [interval]
pid=$1; out=$2; interval=${3:-1}
echo "t_s,rss_mb,vsz_mb,threads,footprint_mb" > "$out"
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  line=$(ps -o rss=,vsz= -p "$pid" 2>/dev/null)
  [ -z "$line" ] && break
  rss=$(echo "$line" | awk '{printf "%.1f", $1/1024}')
  vsz=$(echo "$line" | awk '{printf "%.0f", $2/1024}')
  thr=$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  fp=$(footprint "$pid" 2>/dev/null | awk '/Footprint:/ {for(i=1;i<=NF;i++) if ($i=="Footprint:") {v=$(i+1); u=$(i+2)}; if (u=="GB") v=v*1024; if (u=="KB") v=v/1024; printf "%.0f", v}')
  echo "$(( $(date +%s) - start )),$rss,$vsz,$thr,${fp:-0}" >> "$out"
  sleep "$interval"
done
