#!/bin/bash
# 生成内置英汉词典数据库（dict.db）
#
# 数据源：开源项目 ECDICT（https://github.com/skywind3000/ECDICT）
# 原始库 340 万词 / 812MB，本脚本按「词频 + 柯林斯/牛津核心词」精简到约 4.4 万词 / 9MB
#
# 用法：./scripts/build_dict.sh [保留的高频词数量，默认 50000]
set -e

TOP_N="${1:-50000}"
WORKDIR="$(mktemp -d)"
OUT="$(cd "$(dirname "$0")/.." && pwd)/dict.db"
URL="https://github.com/skywind3000/ECDICT/releases/download/1.0.28/ecdict-sqlite-28.zip"

echo "==> 工作目录：$WORKDIR"
cd "$WORKDIR"

echo "==> 下载开源词典数据（约 200MB，请耐心等待）..."
curl -sS -L --max-time 600 -o ecdict.zip "$URL"
echo "    下载完成：$(du -h ecdict.zip | cut -f1)"

echo "==> 解压..."
unzip -o -q ecdict.zip
echo "    原始库：$(du -h stardict.db | cut -f1)"

echo "==> 精简：词频前 $TOP_N 名 + 柯林斯/牛津核心词"
rm -f dict.db
sqlite3 stardict.db "ATTACH DATABASE 'dict.db' AS s;
CREATE TABLE s.dict AS
  SELECT word, phonetic, definition, translation, pos, exchange, frq, collins, oxford
  FROM stardict
  WHERE (frq BETWEEN 1 AND $TOP_N) OR collins >= 1 OR oxford = 1;
CREATE UNIQUE INDEX s.idx_word ON dict(word COLLATE NOCASE);"

COUNT=$(sqlite3 dict.db "SELECT COUNT(*) FROM dict;")
echo "    精简后词条数：$COUNT"

echo "==> 压缩整理..."
sqlite3 dict.db "VACUUM;"
SIZE=$(du -h dict.db | cut -f1)
echo "    最终大小：$SIZE"

cp dict.db "$OUT"
echo "==> 完成：$OUT ($SIZE, $COUNT 条)"
echo "    提示：重新执行 ./build.sh 即可把新词典打包进 App"

rm -rf "$WORKDIR"
