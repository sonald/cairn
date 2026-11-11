#!/bin/bash
# go.work 仓库：用仓库外的 go.mod/go.sum 副本下载依赖，仓库应保持不变。
set -u
P="$1"; W="$P/work-ws"; ALT="$P/alt-ws"
rm -rf "$W" "$P/mc-ws" "$ALT"; mkdir -p "$W/a" "$W/b" "$ALT/a" "$ALT/b"; cd "$W"
export GOFLAGS=-modcacherw GOTOOLCHAIN=local
printf 'module example.com/ws/a\n\ngo 1.24\n\nrequire github.com/google/go-cmp v0.7.0\n' > a/go.mod
printf 'package a\n\nimport "github.com/google/go-cmp/cmp"\n\nfunc Same(x, y int) bool { return cmp.Equal(x, y) }\n' > a/a.go
printf 'module example.com/ws/b\n\ngo 1.24\n\nrequire github.com/spf13/pflag v1.0.10\n' > b/go.mod
printf 'package b\n\nimport "github.com/spf13/pflag"\n\nvar Flags = pflag.NewFlagSet("b", pflag.ContinueOnError)\n' > b/b.go
printf 'go 1.24\n\nuse (\n\t./a\n\t./b\n)\n' > go.work
for m in a b; do (cd $m && GOWORK=off GOPROXY=off GOSUMDB=off go mod tidy) || exit 1; done
echo "fixture go.sum lines: a=$(wc -l < a/go.sum | tr -d ' ') b=$(wc -l < b/go.sum | tr -d ' ')"
: > a/go.sum                      # a: go.sum 清空
sed -i '' '1d' b/go.sum           # b: 缺一行
git init -q . && git add -A && git -c user.name=probe -c user.email=probe@example.invalid commit -qm base
export GOMODCACHE="$P/mc-ws"       # 空的专用模块缓存，必须联网下载
echo "== 1) 工作区模式下直接 -modfile"
cp a/go.mod a/go.sum "$ALT/a/"; (cd a && go mod download -modfile="$ALT/a/go.mod"); echo "exit=$?"
echo "== 2) 逐模块 GOWORK=off + -modfile"
for m in a b; do cp $m/go.mod $m/go.sum "$ALT/$m/"; (cd $m && GOWORK=off go mod download -modfile="$ALT/$m/go.mod"); echo "$m exit=$?"; done
echo "repo status: [$(git status --porcelain)]"
echo "downloaded: $(cd "$GOMODCACHE" && ls -d github.com/*/* | tr '\n' ' ')"
echo "copy go.sum lines: a=$(wc -l < "$ALT/a/go.sum" | tr -d ' ') b=$(wc -l < "$ALT/b/go.sum" | tr -d ' ')"
echo "== 3) 下载后，沙箱外 go build（GOPROXY=off，仓库 go.sum 仍不完整）"
(cd a && GOPROXY=off go build ./... 2>&1 | head -3); echo "a build exit=$?"
