# nginx + BoringSSL 自动构建

通过 GitHub Actions 自动编译 [nginx](https://nginx.org/) 并静态链接 [BoringSSL](https://boringssl.googlesource.com/boringssl)，支持 Debian 12/13。

## 特性

- **HTTP/3 (QUIC)** — 通过 BoringSSL 启用 `--with-http_v3_module`
- **加密 ClientHello (ECH)** — BoringSSL 原生支持
- **多平台** — 同时构建 Debian 12 (bookworm) 和 Debian 13 (trixie)
- **自动检测最新版** — 触发工作流时自动从 nginx.org 获取最新稳定版
- **静态链接 BoringSSL** — 不依赖系统 OpenSSL，开箱即用

## 使用方式

### GitHub Actions

| 触发方式 | 说明 |
|---|---|
| `git push` / PR | 自动检测 nginx 最新版并构建 |
| 手动触发 | GitHub 页面 → **Actions** → **Build nginx with BoringSSL** → **Run workflow** |

手动触发时可指定：

- **nginx_version** — 指定版本号（如 `1.30.0`），留空则自动检测最新版
- **boringssl_commit** — BoringSSL 分支或 commit（默认 `main`）
- **publish_release** — 勾选后自动创建 GitHub Release

### 构建产物

每个目标平台生成一个 `.tar.gz` 包，包含完整的 nginx 安装目录：

```
nginx-{version}-debian{ver}-x86_64-boringssl.tar.gz
nginx-{version}-debian{ver}-x86_64-boringssl.tar.gz.sha256
nginx-{version}-boringssl                          # 纯二进制文件
```

### 本地构建

```bash
# 安装依赖（Debian/Ubuntu）
sudo apt install build-essential golang-go cmake ninja-build \
  libpcre2-dev zlib1g-dev libxslt1-dev libgd-dev libgeoip-dev \
  perl git

# 构建
export NGINX_VERSION=1.30.0
bash build-nginx.sh

# 产物在 /tmp/nginx-build/artifact/
```

## 内置模块

| 模块 | 说明 |
|---|---|
| `http_ssl_module` | SSL/TLS（BoringSSL） |
| `http_v2_module` | HTTP/2 |
| `http_v3_module` | HTTP/3 (QUIC) |
| `http_realip_module` | 客户端真实 IP |
| `http_addition_module` | 响应追加 |
| `http_sub_module` | 响应替换 |
| `http_dav_module` | WebDAV |
| `http_mp4_module` | MP4 流式 |
| `http_gunzip_module` | 解压 |
| `http_gzip_static_module` | 预压缩静态文件 |
| `http_auth_request_module` | 子请求认证 |
| `http_slice_module` | 范围分片 |
| `http_stub_status_module` | 状态页 |
| `http_image_filter_module` | 图片裁剪缩放 |
| `http_xslt_module` | XSLT 转换 |
| `http_geoip_module` | GeoIP |
| `stream` | TCP/UDP 代理 |
| `mail` | 邮件代理 |

## 项目结构

```
.github/workflows/nginx-build.yml   # GitHub Actions 工作流
build-nginx.sh                       # 构建脚本
```

## 安装到目标系统

```bash
# 解压到根目录
sudo tar xzf nginx-1.30.0-debian12-x86_64-boringssl.tar.gz -C /

# 创建 nginx 用户
sudo useradd -r -s /sbin/nologin -d /var/cache/nginx nginx

# 验证
nginx -V
```
