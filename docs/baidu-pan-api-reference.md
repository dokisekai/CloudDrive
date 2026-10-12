# 百度网盘开放平台 API 完整参考

> **本文档内容汇编自百度网盘开放平台官方文档**（<https://pan.baidu.com/union/doc/>）。
> 每一个接口、参数、返回值、错误码均能在官方原始页面找到对应章节。
> 凡来自官方不同页面间表述不一致之处，统一在 §9「官方文档自述不一致点」中列出，便于实施时做出明确选择。
>
> **接口总数：26 个**（授权 3 · 用户与空间 3 · 文件读取 13 · 下载 1 · 上传 5 · 文件管理 1）
>
> 官方 sitemap 中「基础网盘服务」共 28 个页面；本项目范围内 26 个已逐页核对，另 2 个为「最近服务」「播单能力」（业务域无关，见 §14）。
>
> **文档来源**：
> - 官方根：<https://pan.baidu.com/union/doc/>
> - 错误码（2026-08-13 更新）：<https://pan.baidu.com/union/doc/%E5%B9%B3%E5%8F%B0%E7%AE%80%E4%BB%8B/%E9%94%99%E8%AF%AF%E7%A0%81/>
> - 完整链接见 §13「参考链接」

---

## 0. 全局约定

### 0.1 域名

| 用途 | 域名 |
| --- | --- |
| 业务接口 | `https://pan.baidu.com/rest/2.0/xpan/*` |
| 上传域名发现 | `https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locateupload` |
| 实际上传 | `https://<UPLOAD_HOST>/rest/2.0/pcs/superfile2`（**动态获取，禁止硬编码**） |
| 单步上传 | `https://<UPLOAD_HOST>/rest/2.0/pcs/file?method=upload` |
| 多媒体批量 | `https://pan.baidu.com/rest/2.0/xpan/multimedia` |
| IoT 设备 | `https://pan.baidu.com/rest/2.0/xpan/device` |
| 语义搜索 | `https://pan.baidu.com/xpan/unisearch`（**注意：无 `/rest/2.0` 前缀**） |
| 容量 | `https://pan.baidu.com/api/quota`（**不在 `/rest/2.0/xpan/` 下**，无 `method`） |
| 分类计数 | `https://pan.baidu.com/api/categoryinfo`（**同样无 `method`**，见 C10） |
| OAuth | `https://openapi.baidu.com/oauth/2.0/*` |

### 0.2 认证

所有业务接口 Query 必须带 `access_token`。OAuth `scope` 固定 `basic,netdisk`。

### 0.3 必须携带的 Header

```
User-Agent: pan.baidu.com
```

**所有请求，无例外。** 缺失会命中防盗链 `31326`。注意 302 跳转后仍需保留。

### 0.4 错误码体系（关键）

- 错误码是**业务码，不是 HTTP 状态码** —— 业务错误也返回 `HTTP 200`
- **顶层 `errno == 0` 不代表全部子项成功**（批量接口必须逐项解析 `info[].errno`）
- 🚨 **错误字段名有三套，不能共用一个解析器**：

| 字段名 | 适用接口 |
| --- | --- |
| `errno` / `errmsg` | **绝大多数接口**（含 `/api/quota`，但 quota 无 `errmsg`） |
| `error_code` / `error_msg` | `method=iotqueryuinfo`（IoT） |
| `error_no` / `newno` | `POST /xpan/unisearch`（语义搜索） |

> 拿不到字段名时若一律读 `errno`，`iotqueryuinfo` / `unisearch` 会**静默当成成功**并解析出空数据 —— 这是最容易漏测的一类 bug。

### 0.5 目录围栏

- 应用只能访问 `/apps/{appname}`（`appname` = 建应用时填写的产品名，**不可更改**）
- 网盘内展示为 `/我的应用数据/{appname}`（硬件类应用为 `/我的硬件数据/{appname}`）
- 受限接口：`precreate` / `listall` / `create` / `单步上传` / `filemanager`
- 越界 → `20020` / `31064`

官方明文禁止的行为：查询、下载、转存、写入、移动、复制、删除、重命名权限外目录，以及「通过接口参数、路径拼接、历史链接、缓存记录等方式绕过权限边界」。

---

## 1. 接口总览

> **图例**：✅ 完全可用 · △ 有限制可用 · ❌ 不实现 / 不适用
> 详细分析见 §13「加密库兼容性分析」。

### 授权（`openapi.baidu.com`）

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| A1 | GET | `/oauth/2.0/device/code` | 获取设备码/用户码/二维码 | ✅ |
| A2 | GET | `/oauth/2.0/token?grant_type=device_token` | 轮询换 access_token | ✅ |
| A3 | GET | `/oauth/2.0/token?grant_type=refresh_token` | 刷新 token | ✅ |

### 用户与空间

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| B1 | GET | `/rest/2.0/xpan/nas?method=uinfo` | 用户身份 + **vip_type（分片档位来源）** | ✅ |
| B2 | GET | `/api/quota` | 容量（total/used/free） | ✅ |
| B3 | GET | `/rest/2.0/xpan/device?method=iotqueryuinfo` | IoT 设备 VIP 权限（**桌面端不用**） | ❌ |

### 文件读取

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| C1 | GET | `/rest/2.0/xpan/file?method=list` | **目录枚举（分页）— 日常主用** | ✅ |
| C2 | GET | `/rest/2.0/xpan/file?method=meta` | **单文件元信息 + dlink（推荐）** | ✅ |
| C3 | POST | `/rest/2.0/xpan/file?method=filemetas` | 按 path 批量元信息 | △ |
| C4 | GET | `/rest/2.0/xpan/multimedia?method=filemetas` | 按 fsids 批量（≤100） | △ |
| C5 | GET | `/rest/2.0/xpan/multimedia?method=listall` | 递归列目录（**有 has_more/cursor**） | △ |
| C6 | GET | `/rest/2.0/xpan/multimedia?method=categorylist` | 按类型/后缀筛选（有 cursor） | ❌ |
| C7 | GET | `/rest/2.0/xpan/file?method=search` | 关键词搜索 | ❌ |
| C8 | POST | `/union/xpan/unisearch` | 语义搜索 | ❌ |
| C9 | GET | `/rest/2.0/xpan/file?method=imagelist` | 图片列表（同族族首） | ❌ |
| C10 | GET | `/api/categoryinfo` | **分类文件总个数（独立端点，无 method）** | ❌ |
| C11 | GET | `/rest/2.0/xpan/file?method=doclist` | 文档列表（与 C9 同构） | ❌ |
| C12 | GET | `/rest/2.0/xpan/file?method=videolist` | 视频列表（与 C9 同构） | ❌ |
| C13 | GET | `/rest/2.0/xpan/file?method=btlist` | BT 列表（与 C9 同构） | ❌ |

### 下载

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| D1 | GET | `<dlink>&access_token=<token>` | **实际下载**（支持 Range，但加密场景只对密文偏移有效） | △ |

### 上传

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| E0 | GET | `d.pcs.baidu.com/.../pcs/file?method=locateupload` | 上传域名发现（**expire=60s**） | ✅ |
| E1 | POST | `/rest/2.0/xpan/file?method=precreate` | 预上传 → uploadid + 缺片清单（密文场景不下发明文 MD5） | △ |
| E2 | POST | `<UPLOAD_HOST>/rest/2.0/pcs/superfile2?method=upload` | 上传单个分片 | ✅ |
| E3 | POST | `/rest/2.0/xpan/file?method=create` | 合并分片 → fs_id（**也是创建文件夹端点，`isdir=1`**） | ✅ |
| E4 | POST | `<UPLOAD_HOST>/rest/2.0/pcs/file?method=upload` | 单步上传（≤2GB，官方不推荐） | ❌ |

### 文件管理

| # | 方法 | 路径 | 用途 | 加密 |
| --- | --- | --- | --- | --- |
| F1 | POST | `/rest/2.0/xpan/file?method=filemanager` | copy / move / rename / delete | ✅（对不透明密文容器生效） |

### 1.x 接口数量与实现策略

| 接口总数 | 完全可用 ✅ | 有限制 △ | 不实现 / 不适用 ❌ |
| --- | --- | --- | --- |
| **26** | **12** | **6** | **8** |
| **本项目实际调用** | **12（必实现）** | **5（视场景启用）** | **0** |

> 新增的 5 个（C9 `imagelist` / C10 `categoryinfo` / C11 `doclist` / C12 `videolist` / C13 `btlist`）全部为 ❌ —— 服务端按**真实文件类型/扩展名**分类，密文文件名不命中任何已知分类。
> §13 会进一步说明每个 △ 接口的限制与启用条件。

---

## 2. 授权接口

### A1 获取设备码

```
GET https://openapi.baidu.com/oauth/2.0/device/code
    ?response_type=device_code
    &client_id=<AppKey>
    &scope=basic,netdisk
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `response_type` | M | 固定 `device_code` |
| `client_id` | M | AppKey |
| `scope` | M | 固定 `basic,netdisk` |

响应：

```json
{
  "device_code": "984c2459ec41415c9f5b0137a017fc49",
  "user_code": "8drp69hk",
  "verification_url": "https://openapi.baidu.com/device",
  "qrcode_url": "https://openapi.baidu.com/device/qrcode/a52610ef0eec30da5e45870872317478/8drp69hk",
  "expires_in": 300,
  "interval": 5
}
```

> `expires_in` = device_code 有效期（秒）；`interval` = 轮询间隔，**不得低于 5 秒**
> 二维码兜底 URL：`https://openapi.baidu.com/device?display=mobile&code=<user_code>`

### A2 轮询换 access_token

```
GET https://openapi.baidu.com/oauth/2.0/token
    ?grant_type=device_token
    &code=<device_code>
    &client_id=<AppKey>
    &client_secret=<SecretKey>
```

响应：

```json
{
  "expires_in": 2592000,
  "refresh_token": "127.e4971f79...",
  "access_token": "126.ee2ca559...",
  "scope": "basic netdisk"
}
```

| 字段 | 说明 |
| --- | --- |
| `access_token` | 有效期 **30 天** |
| `refresh_token` | 有效期 **10 年**，**一次性消耗** |

### A3 刷新 token

```
GET https://openapi.baidu.com/oauth/2.0/token
    ?grant_type=refresh_token
    &refresh_token=<RT>
    &client_id=<AppKey>
    &client_secret=<SecretKey>
```

响应同上，**返回新的 `refresh_token`**。

> ⚠️ **必须立即持久化新 refresh_token。** 官方 FAQ：「如果申请了两次 token，第二次申请会导致第一次申请的 access_token 失效」。
> ⚠️ 失败时 `error_description = "invalid refresh"` → **需用户重新扫码授权**（不是应用封禁）。

---

## 3. 用户与空间

### B1 用户身份与 vip 权限 `method=uinfo`

> 🔑 **`vip_type` 是本项目上传分片档位的唯一来源。**

```
GET https://pan.baidu.com/rest/2.0/xpan/nas
    ?method=uinfo
    &access_token=<AT>
    &vip_version=v2
```

请求参数：

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `uinfo` |
| `access_token` | M | OAuth 2.0 Token |
| `vip_version` | — | 固定 `v2`；**传 `v2` 才返回用户实际身份信息** |

响应（官方逐字段）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `errno` | int | `0` 成功 |
| `errmsg` | string | 业务结果描述 |
| `request_id` | string | 请求唯一标识 |
| `baidu_name` | string | 百度账号名 |
| `netdisk_name` | string | 网盘账号名 |
| `avatar_url` | string | 头像地址 |
| **`vip_type`** | int | **不传 `vip_version`（旧含义）**：`0` 普通用户 / `1` 普通会员 / `2` 超级会员<br>**传 `vip_version=v2`**：`0` 普通 / `1` 会员 VIP / `2` 超级会员 SVIP |
| `uk` | int | 用户 ID（`method=download` 需要，见 §9 矛盾 2） |

> ⚠️ 官方响应字段表中**没有 `vip_time`**，会员到期时间不要假定能从本接口拿到。
> ⚠️ `errno = -6` 表示 access_token 失效，或 scope 未含 `netdisk`。
> ⚠️ 头像有 CDN 缓存延迟（换头像后地址不变、需数秒同步），**与本项目无关，不要用于本地缓存键**。
> 错误码：`42905` 查询用户名失败（可重试）。

### B2 容量 `GET /api/quota`

```
GET https://pan.baidu.com/api/quota
    ?access_token=<AT>
    &checkfree=1
    &checkexpire=1
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `access_token` | M | 接口鉴权参数 |
| `checkfree` | — | `1` 检查免费容量，默认 `0` |
| `checkexpire` | — | `1` 检查过期信息，默认 `0` |

```json
{
  "errno": 0,
  "total": 2205465706496,
  "used": 686653888910,
  "free": 1518811817586,
  "expire": false,
  "request_id": 4890482559098510375
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `total` | int | 总空间（字节） |
| `used` | int | 已用空间（字节） |
| `free` | int | 免费容量（字节） |
| `expire` | **bool** | **7 天内是否有容量到期** |

> ⚠️ 此接口**不在 `/rest/2.0/xpan/` 下**，是 `/api/quota`；且**不带 `method` 参数**，打破 `xpan/*` 的统一模式。
> ⚠️ 响应**没有 `errmsg`**。
> 🚨 **同名陷阱**：`expire` 在本接口是 **bool（容量到期标志）**，在 `locateupload` 是 **int（60 秒）**，在 token 接口是**有效期秒数**。三处同名不同义，切勿共用解析代码。
> 该页未列专属错误码，见通用错误码。

### B3 查询用户身份信息及 VIP 权限 `method=iotqueryuinfo`

> ⚠️ **本项目不使用此接口。** 它查的是 **IoT 硬件设备**的 VIP 权益，不是软件应用用户的会员等级。

```
GET https://pan.baidu.com/rest/2.0/xpan/device
    ?method=iotqueryuinfo
    &access_token=<AT>
    &device_id=<DEVICE_ID>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `iotqueryuinfo` |
| `access_token` | M | 接口鉴权参数 |
| `device_id` | **M** | 设备 ID；**软件类型应用拿不到，也不需要** |

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| **`error_code`** | int | 错误码，`0` 成功 |
| **`error_msg`** | string | 错误信息 |
| `request_id` | string | 请求唯一标识 |
| `data` | object | 身份与 IoT 权益数据 |
| `data.has_privilege` | int | 有无特权（SVIP 或未过期的 IoT SVIP → `1`） |
| `data.is_svip` | int | 是否 SVIP |
| `data.is_iot_svip` | int | 是否 IoT SVIP |
| `data.start_time` | uint64 | IoT SVIP 开始时间戳 |
| `data.end_time` | uint64 | IoT SVIP 结束时间戳 |
| `data.now` | int64 | 当前服务器时间戳 |

> 🚨 **两个致命差异，实现时极易踩**：
> 1. 错误字段是 `error_code` / `error_msg`，**不是** `errno` / `errmsg`。复用通用错误解析器会静默失败（拿不到 errno，当成成功）。
> 2. **响应中没有 `vip_type`**。会员档位只能从 **B1 `uinfo`** 取。

---

## 4. 文件读取

### C1 目录枚举 `method=list`

```
GET https://pan.baidu.com/rest/2.0/xpan/file
    ?method=list
    &access_token=<AT>
    &dir=<URL编码的绝对路径>
    &order=name
    &start=0
    &limit=1000
    &web=1
    &folder=0
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `dir` | `/` | 目录绝对路径，中文需 URL 编码 |
| `start` | 0 | 起始位置 |
| `limit` | 1000 | **建议最大不超过 1000** |
| `order` | `name` | `name` / `time` / `size`，**按字符串排序** |
| `desc` | 0 | 1 = 降序 |
| `web` | — | 1 = 返回 `dir_empty` + 缩略图 |
| `folder` | 0 | 1 = **只返回文件夹，且只返回 `path` 字段** |
| `showempty` | 0 | 1 = 返回 `dir_empty` |

**响应 `list[]`**：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `fs_id` | uint64 | 永不变化的唯一 ID |
| `path` | string | 绝对路径 |
| `server_filename` | string | 服务端文件名 |
| `isdir` | int | 0=文件 1=目录 |
| `size` | uint | 文件字节数（目录为 0） |
| `server_ctime` / `server_mtime` | uint | Unix 秒 |
| `local_ctime` / `local_mtime` | uint | 上传时客户端记录的时间 |
| `md5` | string | ⚠️ **文档自相矛盾，见 §9** |
| `category` | int | 1视频 2音频 3图片 4文档 5应用 6其他 7种子 |
| `dir_empty` | int | `web=1` 时：0=有子目录 1=无 |
| `empty` | int | 目录是否为空 |
| `share` / `privacy` / `unlist` | int | 分享/隐私/不在列表 |

> ⚠️ **没有 `has_more` 标志。** 靠 `count < limit` 判断结束。
> ⚠️ **分页中断必须抛错，禁止返回部分结果** —— 否则同步引擎会把未列出的本地记录误判为"已被远端删除"。

---

### C2 单文件元信息 `method=meta`（**推荐**）

```
GET https://pan.baidu.com/rest/2.0/xpan/file
    ?method=meta
    &access_token=<AT>
    &path=<URL编码的绝对路径>
    &dlink=1
```

| 参数 | 说明 |
| --- | --- |
| `path` | M 文件绝对路径 |
| `dlink` | 1 = 返回下载地址 |
| `thumb` | 1 = 返回缩略图 |
| `extra` | 1 = 返回图片拍摄信息 |
| `needmedia` | 1 = 返回视频时长 |
| `web` | 1 = Web 展示字段 |

响应 `list[]` 单元素，包含 `fs_id` / `path` / `filename` / `parent_path` / `isdir` / `size` / `md5` / `dlink` / `server_mtime` 等。

> ✅ **这是下载链路的推荐入口**：只需 path，不需要 `uk`。

### C3 按 path 批量 `method=filemetas`

```
POST https://pan.baidu.com/rest/2.0/xpan/file
Content-Type: application/x-www-form-urlencoded

method=filemetas&access_token=<AT>&target=["/apps/A/f1","/apps/A/f2"]&dlink=1&blocks=0
```

响应 `info[]`，**每项带独立 `errno`**。`blocks=1` 时返回 `block_list`（**按 4MB 分片**）。

### C4 按 fsids 批量 `method=filemetas`

```
GET https://pan.baidu.com/rest/2.0/xpan/multimedia
    ?method=filemetas
    &access_token=<AT>
    &fsids=[123,456]
    &dlink=1&thumb=1&extra=1&needmedia=1&detail=1
```

- `fsids` **最多 100 个**
- 响应 `list[]`
- `path` 参数用于共享目录 `/uk-fsid` 或专属空间 `/_pcs_.appdata/xpan/`，**设置后不返回普通目录文件**

> 三种 meta 调用方式对比：
> | 方式 | 方法 | 入参 | 数组字段 | 限制 |
> |---|---|---|---|---|
> | **`meta`** | GET | `path` | `list[]` | **单文件，推荐** |
> | `filemetas` | POST | `target[]` | `info[]` | 有 per-item errno |
> | `filemetas` | GET | `fsids[]` | `list[]` | ≤100 |

### C5 递归获取文件列表 `method=listall`

> 🔑 **这是唯一自带 `has_more` + `cursor` 的枚举接口**，与 C1 `method=list` 的分页模型完全不同。

```
GET https://pan.baidu.com/rest/2.0/xpan/multimedia
    ?method=listall
    &access_token=<AT>
    &path=<URL编码绝对路径>
    &recursion=1
    &order=name
    &desc=0
    &start=0
    &limit=1000
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `listall` |
| `access_token` | M | 接口鉴权参数 |
| `path` | **M** | 目录绝对路径，必须以 `/` 开头；**仅支持 `/apps/{appname}` 下**；中文需 URL 编码 |
| `recursion` | — | `0` 不递归 / `1` 递归，默认 `0` |
| `order` | — | `time` / `name` / `size`（目录无大小），默认 `name` |
| `desc` | — | `0` 升序 / `1` 降序，默认 `0` |
| `start` | — | 查询起点，默认 `0`；**`has_more=1` 时须改用响应里的 `cursor`** |
| `limit` | — | 默认 `1000`，上限 `10000`（建议 ≤1000） |
| `ctime` | — | 只返回创建时间 > 此时间戳的文件 |
| `mtime` | — | 只返回修改时间 > 此时间戳的文件 |
| `web` | — | `1` 返回缩略图地址 |
| `device_id` | — | 硬件设备场景必传 |

响应：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `errno` | int | `0` 成功 |
| `errmsg` | string | 成功时通常为 `succ` |
| `request_id` | string | 请求唯一标识 |
| **`has_more`** | int | `1` 有下一页 / `0` 无 |
| **`cursor`** | int | **下一页起点，下一次请求作为 `start` 传入** |
| `list` | array | 文件或目录列表 |
| `list[].fs_id` | uint64 | 唯一 ID |
| `list[].path` | string | 完整路径 |
| `list[].server_filename` | string | 文件名 |
| `list[].size` | uint64 | 字节 |
| `list[].md5` | string | 🚨 **云端哈希值，非文件真实 MD5** |
| `list[].category` | int | `1` 视频 `2` 音频 `3` 图片 `4` 文档 `5` 应用 `6` 其他 `7` 种子 |
| `list[].isdir` | int | `0` 否 / `1` 是 |
| `list[].server_ctime` | uint64 | 服务端创建时间戳 |
| `list[].server_mtime` | uint64 | 服务端修改时间戳 |
| `list[].local_ctime` | uint64 | 客户端创建时间戳 |
| `list[].local_mtime` | uint64 | 客户端修改时间戳 |
| `list[].thumbs` | object | 缩略图，`web=1` 时返回 |

错误：

| 码 | 含义 | 处理 |
| --- | --- | --- |
| `42213` | 没有共享目录的权限 | 不可重试 |
| `31034` | **命中频控** | 可重试 |
| `31066` | 文件不存在 | 不可重试 |

> 🚨 **频控**：官方注意事项明确「`listall` 接口请求频率建议不超过**每分钟 8–10 次**」。
> 🔑 **分页铁律**：`has_more=1` 时**必须使用响应中的 `cursor` 作为下一次请求的 `start`，不要自行累加固定步长**（官方原文加粗）。
> 📌 **本项目当前不用它做常规枚举**（频控太紧 + 属 `multimedia` 域）。但它是唯一支持服务端游标翻页的枚举接口，日后做**全量初始同步**时应优先考虑。

### C6 获取分类文件列表 `method=categorylist`

```
GET https://pan.baidu.com/rest/2.0/xpan/multimedia
    ?method=categorylist
    &access_token=<AT>
    &category=3
    &recursion=1
    &limit=1000
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `categorylist` |
| `access_token` | M | 接口鉴权参数 |
| `category` | **M** | `1` 视频 `2` 音频 `3` 图片 `4` 文档 `5` 应用 `6` 其他 `7` 种子；多个用**英文逗号**分隔 |
| `show_dir` | — | `1` 展示文件夹，默认 `0` |
| `parent_path` | — | 起始目录；为空时按根目录递归 |
| `recursion` | — | `0` / `1`，默认 `0` |
| `ext` | — | 扩展名，多个用**英文逗号**分隔；默认该分类下全部 |
| `start` | — | 首次请求默认 `0` |
| `limit` | — | 默认 `1000`，最大 `1000` |
| `order` | — | `time` / `name` / `size`，默认 `time` |
| `desc` | — | `0` 升序 / `1` 降序，默认 `1` |
| `device_id` | — | 硬件设备场景必传 |

响应字段：`errno`、`errmsg`、`request_id`、**`has_more`**、**`cursor`**、`list[]`
（`list[]` 含 `category` / `fs_id` / `md5` / `path` / `server_ctime` / `server_mtime` / `server_filename` / `size` / `thumbs`）

错误：`31034` 频控（一分钟后可重试）、`42215` 查询文件信息失败（可重试）

> ⚠️ `recursion=1` 时**不支持**同时传 `show_dir=1`。
> ⚠️ `has_more=1` 时把 `cursor` **原值**作为下一次 `start`，不要自行累加，**也不要新增 `cursor` 请求参数**（官方原文）。
> ⚠️ `has_more=1` 但 `list` 为空时：先去掉 `ext` 筛选重试，再按 `cursor` 翻页。
> ⚠️ 官方线上参数表把 `desc` 类型写成 `string`，但枚举和示例按 `0/1` 使用 → 见 §9 矛盾 5。
> 📌 **本项目不使用**（存储后端没有「按类型筛选」需求）。

### C7 搜索文件（关键词）`method=search`

```
GET https://pan.baidu.com/rest/2.0/xpan/file
    ?method=search&access_token=<AT>&key=<关键词>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `search` |
| `access_token` | M | 接口鉴权参数 |
| `key` | **M** | 搜索关键字，**最大 30 个 UTF-8 字符** |
| `dir` | — | 搜索目录，默认根目录 |
| `category` | — | `1`~`7`，同 `list[].category` |
| `num` | — | 官方参数表：**默认 500 且不可修改** |
| `recursion` | — | **携带即递归，不携带即不递归**（无值语义） |
| `web` | — | **携带即返回缩略图**（无值语义） |
| `device_id` | — | 硬件设备场景必传 |

响应：`errno`、`request_id`、**`has_more`**、`list[]`（`category` / `fs_id` / `isdir` / `local_ctime` / `local_mtime` / `server_ctime` / `server_mtime` / `md5` / `size` / `thumbs` / `path` / `server_filename` / `share` / `oper_id` / `extent_tinyint1`）、`contentlist`

> ⚠️ 官方线上旧请求示例带 `page=1`，但参数表未定义 `page` → 见 §9 矛盾 6。
> 📌 **本项目不使用**。

### C8 搜索文件（语义搜索）`POST /xpan/unisearch`

```
POST https://pan.baidu.com/xpan/unisearch
     ?scene=mcpserver&access_token=<AT>&query=<自然语言>
Content-Type: application/json
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `access_token` | M | 鉴权令牌 |
| `scene` | M | **固定 `mcpserver`** |
| `query` | M | 搜索内容，如「帮我在网盘里查找北京故宫的图片」 |
| `dir` | — | `[]string`，默认 `["/"]` |
| `category` | — | `[]int`，默认 `[]` 表示不限 |
| `num` | — | 最大返回数量，默认 `500` |
| `stream` | — | 是否流式响应，默认 `0` |
| `search_type` | — | `0` 简单 / `1` 语义 / `2` 自动（>5 字走语义，≤5 字走简单），默认 `0` |
| `sources` | — | `[]int`；简单来源 `[4,5,11,13,14]`，语义追加 `[7,8,9]` |
| `data` | **M** | JSON 对象；官方示例传 `{}`，但同时标注了非空校验 → 见 §9 矛盾 6 |

响应：`error_no` / `newno` / `error_msg` / `request_id` / `server_time` / `is_end` / `extra_info` / `data[].list[]`
（`category` / `filename` / `fsid` / `isdir` / `parent_path` / `path` / `content` / `pid` / `ocr` / `server_ctime` / `server_mtime` / `size`）

> ⚠️ 错误字段是 `error_no` / `newno`，**不是 `errno`**（第三个例外，见 B3）。
> 📌 **本项目不使用**。

### C9 图片列表 `method=imagelist`

> 📚 **与 C11/C12/C13 同族**：`doclist` / `videolist` / `btlist` 参数与响应结构完全一致，仅 `method` 不同。
> 📌 **本项目不使用**（服务端按真实扩展名分类，密文文件名不命中）。

```
GET https://pan.baidu.com/rest/2.0/xpan/file
    ?method=imagelist
    &access_token=<AT>
    &parent_path=<URL编码绝对路径>
    &web=1
    &recursion=1
```

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `method` | string | 是 | 固定 `imagelist` |
| `access_token` | string | 是 | OAuth 2.0 Token |
| `parent_path` | string | M | `/apps/<APP_NAME>/<FOLDER_NAME>`；**参数名是 `parent_path`，不是 `dir`** |
| `web` | int | — | `1` 时返回 `thumbs` 缩略图信息 |
| `recursion` | int | — | `1` 遍历子目录；大目录需结合分页与限流 |
| `page` | int | — | **不传则不分页**；传了才用 `num` 控制每页数量 |
| `num` | int | — | 每页数量，仅在传 `page` 时生效；**按修改时间倒序排列** |

**响应**：

```json
{
  "errno": 0,
  "guid_info": "",
  "info": [
    {
      "server_mtime": 1596078006,
      "category": 3,
      "fs_id": 123456789012347,
      "server_ctime": 1475996315,
      "isdir": 0,
      "local_mtime": 1475996315,
      "local_ctime": 1475996315,
      "size": 233999,
      "md5": "<IMAGE_MD5>",
      "share": 0,
      "path": "/apps/<APP_NAME>/<IMAGE_FILE>.jpg",
      "server_filename": "<IMAGE_FILE>.jpg",
      "object_key": "<OBJECT_KEY>",
      "thumbs": {
        "icon": "<THUMB_ICON_URL>",
        "url1": "<THUMB_URL_1>",
        "url2": "<THUMB_URL_2>",
        "url3": "<THUMB_URL_3>"
      }
    }
  ],
  "request_id": 1234567890,
  "guid": 0
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `errno` | int | `0` 成功 |
| `guid_info` | string | 官方示例返回空串 |
| `info[]` | array | 文件条目数组 |
| `info[].category` | int | 文件分类（图片为 `3`） |
| `info[].share` | int | 是否已分享，`0` 未分享 |
| `info[].object_key` | string | 底层存储对象键 |
| `info[].thumbs` | object | **仅 `web=1` 时返回**；含 `icon` / `url1` / `url2` / `url3` 四个尺寸 |
| `request_id` | uint64 | 请求唯一标识 |
| `guid` | int | 官方示例返回 `0` |

**官方注意事项 4 条**：

1. 示例代码中的 `access_token` 替换为自行获取的有效令牌
2. **不传 `page` 时不分页**；传入 `page` 后使用 `num` 控制每页数量，**按修改时间倒序排列**
3. **只有 `web=1` 才返回 `thumbs`**；缩略图地址过期后需重新请求列表
4. **`recursion=1` 会遍历子目录**；目录较大时应结合分页和限流

> 🔑 分页语义与 C1 `list` **完全不同**：C1 用 `start` + `limit`，本族用 `page` + `num`，且**不传 `page` 就不分页**（一次性全量返回）。
> ⚠️ `md5` 同属「云端哈希」，见 §9 矛盾 1。

### C10 分类文件总个数 `GET /api/categoryinfo`

> 🚨 **这是最容易漏掉的接口**：它**不在 `/rest/2.0/xpan/` 下，也不带 `method` 参数**，是独立的 `/api/` 端点（与 `/api/quota` 同一类打破统一模式的接口）。

```
GET https://pan.baidu.com/api/categoryinfo
    ?access_token=<AT>
    &category=3
    &parent_path=<URL编码绝对路径>
    &recursion=0
```

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `access_token` | string | M | OAuth 2.0 Token |
| `category` | int | M | 分类码（如 `3` = 图片） |
| `parent_path` | string | M | 目录绝对路径 |
| `recursion` | int | — | `0` 不递归 / `1` 递归子目录 |

**响应**：

```json
{
  "errno": 0,
  "info": {
    "3": {
      "total": 2,
      "size": 3746464,
      "count": 2
    }
  },
  "request_id": 5000835837369146640
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `errno` | int | `0` 成功 |
| **`info`** | **object** | 🚨 **不是数组！** 是以 category 码为 key 的字典 |
| `info.<category>.total` | int | 总个数 |
| `info.<category>.size` | int | 总字节数 |
| `info.<category>.count` | int | 文件个数（官方示例中与 `total` 同值） |
| `request_id` | uint64 | 请求唯一标识 |

> 🚨 **`info` 的 wire type 与所有其他接口都不同**：
> - `C1 list` / `C9 imagelist` 等 → `info` 是**数组**
> - C4 `filemetas` → `info` 是**数组**（含 `errno` 子项）
> - **C10 `categoryinfo` → `info` 是 object（字典）**
>
> 实现时不能共用同一个 `info` 解码类型。
> 📌 **本项目不使用**（密文场景无意义）。

### C11 文档列表 `method=doclist`

参数与响应结构**完全同 C9**，仅 `method` 不同。

| 参数 | 值 |
| --- | --- |
| `method` | `doclist` |
| 其余 | 同 C9（`parent_path` / `web` / `recursion` / `page` / `num`） |

响应 `info[].category` 为文档分类码。**本项目不使用。**

### C12 视频列表 `method=videolist`

参数与响应结构**完全同 C9**，仅 `method` 不同。

| 参数 | 值 |
| --- | --- |
| `method` | `videolist` |
| 其余 | 同 C9 |

响应 `info[].category` 为视频分类码。**本项目不使用。**

### C13 BT 列表 `method=btlist`

参数与响应结构**完全同 C9**，仅 `method` 不同。

| 参数 | 值 |
| --- | --- |
| `method` | `btlist` |
| 其余 | 同 C9 |

响应 `info[].category` 为 BT 分类码。**本项目不使用。**

> ⚠️ **普通用户无法上传视频**（§10 约束 15），且普通用户**不支持创建 BT 任务**；此接口对普通用户基本无效。

---

## 5. 下载

### D1 三阶段流程

```
① method=list  或  method=meta    → 拿到 fs_id / 确认存在
② method=meta  dlink=1            → 拿到 dlink
③ GET  <dlink>&access_token=<AT>  → 二进制流
```

### 5.1 dlink 规则（逐条照做）

| 规则 | 说明 | 违反后果 |
| --- | --- | --- |
| 有效期 **8 小时** | 过期需重新取 | `31360` |
| **必须拼 `&access_token=<AT>`** | 拼在已有 query 后 | — |
| **必须 `User-Agent: pan.baidu.com`** | — | `31326` 防盗链 |
| **禁止重新编码 query** | 只做字符串拼接 | `31362` 签名错误 |
| **可能 302** | 需跟随且保留鉴权参数 | — |
| 中文需注意 unicode 解码 | — | — |

> ⚠️ **实现要点**：`dlink` 里已含签名参数，**绝不能用 `URLComponents.queryItems` 重建**，必须 `dlink + "&access_token=" + token` 原始字符串拼接。

### 5.2 Range

```
Range: bytes=0-499      # 前 500 字节
Range: bytes=500-999    # 第二段
Range: bytes=-500       # 末 500 字节
Range: bytes=500-       # 偏移 500 到结尾
```

`downloadRange` 可直接透传，无需分片下载实现。

---

## 6. 上传

### 6.1 能力说明（**硬限制**）

官方《上传 > 能力说明》原文给出的限制：

| 限制 | 内容 | 来源 |
| --- | --- | --- |
| **分片数量** | **不得超过 1024 个** | 能力说明 |
| 普通用户 | 单文件 ≤ **4 GB** | 能力说明 |
| 普通会员 | 单文件 ≤ **10 GB** | 能力说明 |
| 超级会员 | 单文件 ≤ **20 GB** | 能力说明 |
| 类型 | **普通用户无法上传视频、Live Photo** | 能力说明 |
| 目录 | 仅 `/apps/{appname}` | 能力说明 |

**能力说明页没有给出分片大小。** 分片大小 4/16/32 MB 来自《分片上传》页与错误码 `31364`，属于另一处口径（见 §9 矛盾 4）：

| 用户身份 | 单文件上限 | 分片大小 | 分片数 | 余量 |
| --- | --- | --- | --- | --- |
| 普通 `vip_type=0` | 4 GB | 4 MB | 1024 | **0 片余量，正好卡满** |
| 会员 `vip_type=1` | 10 GB | 16 MB | 640 | 384 片余量 |
| SVIP `vip_type=2` | 20 GB | 32 MB | 640 | 384 片余量 |

> 🔑 **`1024` 是独立于大小的硬约束。**
> → 实现时必须校验 `ceil(size / sliceSize) <= 1024` **且** `size <= tier.maxFileSize`，两者都要查。
> ⚠️ 第三方实现 `gitee.com/hefy27/pan-client` 用的是 `MaxSliceNum=2048`，与官方冲突，**一律以官方 1024 为准**。

### 6.2 E0 上传域名发现

```
GET https://d.pcs.baidu.com/rest/2.0/pcs/file
    ?method=locateupload
    &appid=250528
    &access_token=<AT>
    &path=<URL编码路径>
    &uploadid=<UPLOAD_ID>
    &upload_version=2.0
```

```json
{
  "error_code": 0,
  "expire": 60,
  "host": "c.pcs.baidu.com",
  "servers":      [{ "server": "https://c3.pcs.baidu.com" }],
  "bak_servers":  [{ "server": "https://c.pcs.baidu.com" }],
  "quic_servers": [{ "server": "https://panup.pcs.baidu.com" }]
}
```

| 规则 | 说明 |
| --- | --- |
| **`expire` = 60 秒** | 官方：「不要长期缓存或固定写死上传服务器地址」 |
| 优先 `servers[]` 中的 **HTTPS** | 保留协议 + 主机名 |
| `path` / `uploadid` 必须与当前任务一致 | 不能跨任务混用 |

### 6.3 E1 预上传 `method=precreate`

```
POST https://pan.baidu.com/rest/2.0/xpan/file?method=precreate&access_token=<AT>
Content-Type: application/x-www-form-urlencoded

path=<URL编码>&size=<字节>&isdir=0&autoinit=1&rtype=3
&block_list=["<MD5_0>","<MD5_1>"]
&content-md5=<整文件MD5>&slice-md5=<前256KB的MD5>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `path` | M | 与后续分片/合并**必须逐字一致** |
| `size` | M | 与实际一致，**上传目录时固定为 0** |
| `isdir` | M | `0` 文件 / `1` 目录 |
| `block_list` | M | 各分片 MD5 的 JSON 字符串数组，**32 位小写** |
| `autoinit` | M | **固定 `1`** |
| `rtype` | — | `1` 冲突重命名 / `2` 冲突且 `block_list` 不同才重命名 / `3` 覆盖同名文件 |
| `uploadid` | — | 续传时传入已有 ID |
| `content-md5` | — | 整文件 MD5（秒传），32 位小写 |
| `slice-md5` | — | **文件前 256 KB** 校验段的 MD5（秒传），32 位小写 |
| `local_ctime` | — | 客户端创建时间戳，**默认当前时间** |
| `local_mtime` | — | 客户端修改时间戳，**默认当前时间** |

响应：

```json
{
  "errno": 0,
  "path": "/apps/A/f.bin",
  "uploadid": "<UPLOAD_ID>",
  "return_type": 1,
  "block_list": [0, 1, 2]
}
```

| 字段 | 说明 |
| --- | --- |
| `uploadid` | 上传任务唯一 ID |
| `return_type` | 系统内部状态字段 |
| `block_list` | **需要上传的分片序号数组，索引从 0 开始** |

> 🔑 **`block_list` = 需要上传的分片序号。**
> - `[]` 或空 → **整个文件云端已存在（秒传成功）**，可直接跳到 E3 或直接返回
> - `[0]` → 只有一个分片
> - `[0,1,2]` → 只传这三片
> **这是断点续传的天然机制**：重新 precreate，云端会告诉你还缺哪几片。
> 📌 官方注意事项：**文件 < 4 MB 时 `block_list` 只含文件整体 MD5**；> 4 MB 才需本地切分并按顺序提交每片 MD5。
> ⚠️ 官方 `rtype` 枚举**不含 `0`**（与 `create` 的 `rtype` 枚举不同，见 §6.5 / §6.7）。默认走服务端策略。
> 错误：`-7` 文件或目录名错误 / 无权访问，`-10` 容量不足。

### 6.4 E2 分片上传

```
POST https://<UPLOAD_HOST>/rest/2.0/pcs/superfile2
    ?method=upload
    &access_token=<AT>
    &type=tmpfile
    &path=<与 precreate 一致>
    &uploadid=<与 precreate 一致>
    &partseq=<分片序号，从 0 开始>
Content-Type: multipart/form-data

file=<分片二进制>
```

**请求参数（官方逐字段）**：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `method` | string | 是 | 固定 `upload` |
| `access_token` | string | 是 | OAuth 2.0 Token |
| `type` | string | 是 | 固定 `tmpfile` |
| `path` | string | 是 | `/apps/<APP_NAME>/filename.jpg`；**URL 编码**，与 precreate 一致 |
| `uploadid` | string | 是 | precreate 返回的上传任务 ID |
| `partseq` | int | 是 | 分片序号，从 `0` 开始；取自 precreate 返回的 `block_list` |
| `file` | byte array | 是 | 当前分片的二进制内容 |

**响应参数（官方逐字段）**：

| 字段路径 | 类型 | 描述 |
| --- | --- | --- |
| `md5` | string | **文件分片的云端 MD5，分片上传成功时返回** |
| `request_id` | uint64 | 请求唯一标识 |
| `errno` | int | **仅失败响应中包含的业务错误码**；成功响应不返回此字段 |

成功响应示例：

```json
{
  "md5": "<BLOCK_MD5_0>",
  "request_id": 8383464737849269312
}
```

> 🔑 **官方说明**：「返回的 md5 应与预上传请求 block_list 中当前分片对应的值一致」—— 这就是为什么 `block_list` 必须用分片接口**返回的** md5，本地算的不能用（云端哈希非真实 MD5，见 §9 矛盾 1）。
> 📌 **成功响应只有 `md5` + `request_id` 两个字段，没有 `errno`**。失败响应会带 `errno`，实现时按「有 `errno` 且非 0 → 失败」判定。

**错误码**：

| 码 | 含义 | 排查 |
| --- | --- | --- |
| `31024` | 没有申请上传权限 | 控制台开通上传权限 |
| `31299` | 第一个分片大小小于 4 MB | 非末片必须达到分片大小 |
| `31364` | 超出分片大小限制 | 按授权用户身份限制调整分片大小 |
| `31363` | 分片缺失 | 1.分片是否全部上传；2.每个上传的分片是否正确；3.`size` 是否与实际文件及 precreate 的 `size` 一致 |

更多错误码参考 §11 公共错误码。

**官方注意事项 5 条**：

1. 上传域名必须通过 [获取上传域名](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E8%8E%B7%E5%8F%96%E4%B8%8A%E4%BC%A0%E5%9F%9F%E5%90%8D/) 接口获取，**不要在生产代码中固定示例域名**
2. 占位符 `<ACCESS_TOKEN>` / `<UPLOAD_ID>` 替换为当前任务的有效值；文档、日志和截图中只使用占位符
3. **文件 ≤ 4 MB 时无需切片，可直接上传一次**
4. 普通用户单分片固定 4 MB、单文件上限 4 GB；会员单分片上限 16 MB、单文件上限 10 GB；超级会员单分片上限 32 MB、单文件上限 20 GB
5. `path`、`uploadid` 和分片顺序必须与 precreate 结果一致；**只上传 precreate 响应 `block_list` 指定的分片**

### 6.5 E3 合并 `method=create`

```
POST https://pan.baidu.com/rest/2.0/xpan/file?method=create&access_token=<AT>
Content-Type: application/x-www-form-urlencoded

path=<与 precreate 一致>&size=<与 precreate 一致>&isdir=0
&rtype=3&uploadid=<UPLOAD_ID>
&block_list=["<分片返回的MD5_0>","<MD5_1>",...]
```

响应：

```json
{
  "errno": 0,
  "fs_id": 693789892866840,
  "md5": "7d57c40c9fdb4e4a32d533bee1a4e409",
  "server_filename": "f.bin",
  "path": "/apps/A/f.bin",
  "size": 2626327,
  "ctime": 1545969541,
  "mtime": 1545969541,
  "isdir": 0
}
```

> 🔑 `block_list` 必须用**分片上传接口返回的 md5**，严格按 `partseq` 顺序排列
> 🔑 `path` / `size` / `isdir` / `rtype` / `block_list` 必须与 precreate **完全一致**
> 🔑 全部 `block_list` 指定的分片成功后才能调用

错误：`31190` 文件不存在 / `31355` uploadid 参数异常 / `31363` 分片缺失 / `31365` 总大小超限

### 6.6 E4 单步上传（不推荐）

```
POST https://<UPLOAD_HOST>/rest/2.0/pcs/file
     ?method=upload&access_token=<AT>&path=<路径>&ondup=fail
Content-Type: multipart/form-data
file=<完整文件>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `upload` |
| `access_token` | M | 接口鉴权参数 |
| `path` | M | 上传文件绝对路径，需 URL 编码 |
| `ondup` | — | `fail` 冲突失败 / `overwrite` 覆盖 / `newcopy` 重命名，默认 `fail` |
| `file` | M | 文件二进制内容（multipart） |

响应：`errno`、`path`、`size`、`ctime`、`mtime`、`md5`、`fs_id`、`request_id`

| 码 | 含义 | 排查 |
| --- | --- | --- |
| `31024` | **没有申请上传权限** | 控制台开通 |
| `31061` | 文件已存在 | 检查 `ondup` 与目标路径 |
| `31064` | 上传路径错误 | 确认 `path` 在 `/apps/{appname}` 下且已 URL 编码 |

- **上限 2 GB**
- 官方原文：「**通用上传场景建议优先使用分片上传流程**」「此接口可能存在能力限制」
- 上传域名必须通过 E0 动态获取，**优先 HTTPS**

> ✅ 结论：**不使用单步上传**。统一走 precreate → superfile2 → create 全流程，4MB 以下自然退化为单片。

### 6.7 创建文件夹 `method=create`（与创建文件同端点）

> 🔑 **创建文件与创建文件夹共用 `POST /rest/2.0/xpan/file?method=create`**，靠 `isdir` 与参数集合区分。

```
POST https://pan.baidu.com/rest/2.0/xpan/file?method=create&access_token=<AT>
Content-Type: application/x-www-form-urlencoded

path=<URL编码绝对路径>&isdir=1&rtype=0&mode=1
&local_ctime=<Unix秒>&local_mtime=<Unix秒>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `method` | M | 固定 `create` |
| `access_token` | M | 接口鉴权参数 |
| `path` | **M** | 待创建文件夹的绝对路径，需 URL 编码 |
| `isdir` | **M** | **本接口固定为 `1`** |
| `rtype` | — | `0` 冲突时失败（默认）/ `1` 路径冲突时重命名 |
| `local_ctime` | — | 客户端创建时间戳，**默认当前时间** |
| `local_mtime` | — | 客户端修改时间戳，**默认当前时间** |
| `mode` | — | 创建来源：`1` 手动 / `2` 批量上传 / `3` 文件自动备份 / `4` 相册自动备份 / `5` 视频自动备份 |

响应：

```json
{
  "errno": 0,
  "status": 0,
  "request_id": 1234567890,
  "fs_id": 693789892866840,
  "category": 6,
  "path": "/apps/A/newdir",
  "ctime": 1545969541,
  "mtime": 1545969541,
  "isdir": 1
}
```

| 字段 | 说明 |
| --- | --- |
| `status` | 创建状态，`0` 成功 |
| `fs_id` | 文件夹云端唯一标识 |
| `category` | 文件分类，文件夹通常返回 `6` |
| `ctime` / `mtime` | 创建 / 修改时间戳 |
| `isdir` | 固定 `1` |

| 码 | 含义 | 排查 |
| --- | --- | --- |
| `-7` | 文件或目录名错误或无权访问 | 检查 `path` 格式与围栏 |
| `-8` | **文件或目录已存在** | 检查 `rtype` 与目标路径 |
| `-10` | 云端容量已满 | 清理或扩容 |

> 🔑 **不要传 `size` / `block_list` / `uploadid`。**
> ⚠️ 本接口 `rtype` 只有 `0` / `1` 两个值，**没有 `3`（覆盖）**。要「已存在就复用」必须用 `errno=-8` 判定后走业务分支，**不能靠 rtype=3**。
> 📌 同步引擎里 `createDirectory` 应固定 `rtype=0`，让 `-8` 明确冒泡为「已存在」，比 `rtype=1` 静默重命名更安全。

---

## 7. 文件管理 F1 `method=filemanager`

```
POST https://pan.baidu.com/rest/2.0/xpan/file
     ?method=filemanager&access_token=<AT>&opera=<copy|move|rename|delete>
Content-Type: application/x-www-form-urlencoded

async=<0|1|2>
ondup=<fail|newcopy|overwrite|skip>     # delete 不使用
filelist=<JSON 数组>
```

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `opera` | M | `copy` / `move` / `rename` / `delete` |
| `async` | — | `0` 强制同步 / `1` 服务端按文件数量自适应 / `2` 强制异步；**最终以响应是否返回 `taskid` 为准** |
| `ondup` | — | 全局策略；**单文件参数优先级更高**；`delete` 无此参数 |
| `filelist` | M | 合法 JSON，英文半角双引号；不要直接复制弯引号示例 |

**`filelist` 结构**（按 `opera` 提交对应数组）：

| `opera` | `filelist` 内单元素字段 | 说明 |
| --- | --- | --- |
| `copy` | `path` + `dest` + `newname` | `path` 源、`dest` 父目录、`newname` 新名（可选，留空沿用旧名） |
| `move` | `path` + `dest` + `newname` | 同上含义 |
| `rename` | `path` + `newname` | `dest` 不需要 |
| `delete` | **字符串数组** `["path1", "path2"]` | 不是对象数组 |

示例：

```json
{
  "copy":   [{"path": "/apps/A/src", "dest": "/apps/A/dst", "newname": "c.txt"}],
  "move":   [{"path": "/apps/A/src", "dest": "/apps/A/dst", "newname": "m.txt"}],
  "rename": [{"path": "/apps/A/src", "newname": "r.txt"}],
  "delete": ["/apps/A/src"]
}
```

**响应 — 同步（`async=0` 或自适应判定为同步）**：

```json
{
  "errno": 0,
  "info": [
    {
      "errno": 0,
      "path": "/apps/<APP_NAME>/abc"
    }
  ],
  "request_id": 9131857965670515801
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `errno` | int | 顶层结果码；`0` 才表示请求被受理 |
| `info[]` | array | **每项操作一条**；必须逐项读 `errno` |
| `info[].errno` | int | 子项结果；同步时**必填**，逐项判断 |
| `info[].path` | string | 该子项对应路径 |
| `request_id` | uint64 | 请求唯一标识 |

**响应 — 异步（有 `taskid`）**：

```json
{
  "errno": 0,
  "info": [],
  "request_id": 9132303301733449639,
  "taskid": 569942193355668
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `taskid` | uint64 | 异步任务 ID；服务端稍后自处理 |
| `info` | array | 异步场景下**始终为 `[]`**；结果不能从本响应获取，必须改用查询接口或复用同步模式 |

**官方注意事项 6 条**：

1. 占位符替换说明；文档、日志、截图只使用占位符
2. `ondup` 分为全局参数和单文件参数，**单文件参数优先级更高**
3. `async=0` 强制同步；`async=2` 强制异步；`async=1` 服务端按文件数量自适应；**最终以响应是否返回 `taskid` 为准**
4. `delete` 操作**没有 `ondup` 选项**；失败后可查错误码再重新发起
5. `filelist` 必须是合法 JSON 字符串，使用英文半角双引号；**不要直接复制弯引号示例**
6. 开放平台仅限制异常行为；正常使用遇到问题见反馈与支持

> 🔑 **顶层 `errno == 0` 不代表全部成功。必须逐项读 `info[].errno`。**
> 与 WebDAV `207 Multi-Status` 同一类陷阱。
> 🔑 单条操作用 `async=0` 强制同步，才能直接拿到 `info[].errno`
> 🔑 `delete` **移入回收站**（普通用户 10 天，SVIP 180 天），**非永久删除**，无 `ondup`
> 🔑 错误码：`111` 有其他异步任务正在执行（退避重试）、`-9` 不存在、`-7` 文件名非法

---

## 8. 端到端时序（实现依据）

### 8.1 列目录 `listDirectory`

```
for start in stride(from: 0, to: .max, by: limit) {
    resp = GET method=list &dir=<远端路径> &start &limit=1000 &order=name
    guard errno == 0 else throw          # -7 无权限 / -9 不存在
    items += resp.list
    if resp.list.count < limit: break
    start += limit
}
```

> ⚠️ 中途任何异常**必须抛出**，绝不能返回部分数组。
> ⚠️ 虚拟路径 `/` → 远端 `/apps/{appname}`。

### 8.2 下载文件 `downloadFile`

```
1. meta = GET method=meta &path=<远端> &dlink=1
   guard errno == 0 else mapError
2. dlink = meta.list[0].dlink
3. url  = dlink + "&access_token=" + token     # 字符串拼接！
4. GET url  Headers: { User-Agent: "pan.baidu.com", Range: "bytes=\(offset)-\(end)" }
   - 跟随 302，保留 Header
   - errno 31360 → 删除 dlink 缓存，重取一次
   - errno 31326 → 检查 UA
   - errno 31362 → 检查是否误用 URLComponents 重编码
```

### 8.3 范围下载 `downloadRange`

同 8.2，仅追加 `Range` 头。**百度原生支持 Range，无需自行分片。**

### 8.4 上传 `uploadFile`（含断点续传）

```
tier = BaiduPanTier(vip_type)               // 4/16/32 MB
sliceSize = tier.sliceSize
sliceCount = ceil(size / sliceSize)
guard sliceCount <= 1024 else throw         // 硬限制
guard size <= tier.maxFileSize else throw   // 4/10/20 GB

blockMD5 = 本地切分并逐片计算 MD5
contentMD5 = 整文件 MD5
sliceMD5   = 前 256KB 的 MD5

// —— 断点续传入口 ——
ckpt = DB.load(path)
if ckpt != nil { uploadid = ckpt.uploadid }

// ① precreate（带上已有 uploadid 即为续传）
pre = POST method=precreate
      path, size, isdir=0, autoinit=1, rtype=3,
      block_list=blockMD5, content-md5, slice-md5
      [, uploadid = ckpt.uploadid]
guard pre.errno == 0
uploadid = pre.uploadid
DB.saveCheckpoint(path, uploadid, ...)

if pre.block_list.isEmpty {
    // 秒传命中，云端已存在 → 直接返回
    DB.clearCheckpoint(path); return
}

// ② locateupload（60s 有效，每次现取）
host = GET locateupload(appid=250528, path, uploadid).servers[0].server

// ③ 逐片上传（可并发）
for seq in pre.block_list {
    resp = POST host/superfile2
             method=upload &type=tmpfile &path &uploadid &partseq=seq
             file=<第 seq 片>
    resultMD5[seq] = resp.md5                 // 必须用返回值
    DB.markSliceDone(path, seq)
}

// ④ 合并
created = POST method=create
           path, size, isdir=0, rtype=3, uploadid,
           block_list=resultMD5 按 seq 升序
guard created.errno == 0
DB.clearCheckpoint(path)
return created                                // fs_id / md5 / mtime
```

**关键点**：

| 项 | 要求 |
| --- | --- |
| 续传判据 | **以云端返回的 `pre.block_list` 为准**，不信任本地记录 |
| `resultMD5` | 必须用**分片接口返回的 md5**，不能用本地算的 |
| `path`/`size`/`block_list` | precreate 与 create 必须逐字一致 |
| 上传域名 | 60 秒有效，**不要缓存** |
| 并发 | 默认 3，最高 32 |

### 8.5 创建目录 `createDirectory`

```
POST method=create &path=<远端> &isdir=1 &rtype=0 &mode=1
```

- **不传** `size` / `block_list` / `uploadid`
- `rtype=0` 让「已存在」以 `errno=-8` 明确冒泡；**不要用 `rtype=1`**（会静默重命名成 `dir(1)`，同步引擎无法察觉）
- 目录已存在时，在客户端把它当作幂等成功（先 `meta` 探测或捕获 `-8` 后转成功）

### 8.6 移动 / 重命名 `move`

```
// 跨目录移动（含改名）
opera=move, async=0,
filelist=[{"path": src, "dest": dstParent, "newname": dstLeaf}]

// 同目录改名
opera=rename, async=0,
filelist=[{"path": src, "newname": newName}]
```

> 逐项校验 `info[].errno`。异步返回 `taskid` 时不能视为成功。

### 8.7 复制 `copy`

```
opera=copy, async=0, ondup=<fail|newcopy|overwrite>,
filelist=[{"path": src, "dest": dstParent, "newname": dstLeaf}]
```

### 8.8 删除 `delete`

```
opera=delete, async=0,
filelist=["<绝对路径>"]       // 注意是字符串数组，不是对象数组
```

> 移入回收站，非永久删除。

### 8.9 存在性检查 `exists`

```
meta = GET method=meta &path=<远端>       # 不带 dlink，省流量
errno == 0  → true
errno == -9 / -3 → false
其他 → throw
```

---

## 9. 官方文档矛盾点与裁决

实现前必须知道这六处，踩错会出隐蔽 bug。

### ⚠️ 矛盾 1：`md5` 字段语义

| 文档 | 描述 |
| --- | --- |
| [获取文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) | `list[].md5` = 「云端哈希（**非文件真实 MD5**）」 |
| [递归获取文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E9%80%92%E5%BD%92%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) | 同上：「**云端哈希值，非文件真实 MD5**」 |
| [获取分类文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E8%8E%B7%E5%8F%96%E5%88%86%E7%B1%BB%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) · [搜索文件](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%90%9C%E7%B4%A2%E6%96%87%E4%BB%B6%E5%85%B3%E9%94%AE%E8%AF%8D%E6%90%9C%E7%B4%A2/) | 同上：「云端哈希，非文件真实 MD5」 |
| [查询文件信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%9F%A5%E8%AF%A2%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/) | `list[].md5` = 「文件内容 MD5，**可用于校验和秒传**」 |
| 创建文件 / 单步上传 响应 | `md5` = 「文件的**云端** MD5」 |

**裁决**：`md5` **不作为内容校验依据**。

- 合成 ETag 用 `fs_id + size + server_mtime`
- 秒传完全交给 `precreate` 服务端判断（看返回的 `block_list` 是否为空），**不自己比对 md5**
- 若一定要做内容校验，本地算 MD5 与远端 md5 不一致时，**判定为 md5 不可靠，而非文件损坏**
- 一句话：**4 个枚举接口明说不可信，1 个查询接口说可信 —— 取不可信那一侧**，因为枚举是同步引擎的高频路径。

### ⚠️ 矛盾 2：dlink 的获取方式

| 文档 | 描述 |
| --- | --- |
| [下载](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8B%E8%BD%BD/) | 正文说三阶段 `list → 查询文件信息(dlink=1) → GET dlink`，但「源接口请求」写的是 `method=download`，需 `app_id` + **`user_id`** + `path` + `check_blue=1` + `esl=1` |
| [查询文件信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%9F%A5%E8%AF%A2%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/) | 主用 `method=meta`（GET + path + dlink=1） |

**裁决**：**用 `method=meta`（按 path）**。

- 不需要 `user_id`(uk)，省掉一次 `uinfo` 调用
- 与下载文档的正文描述一致
- `method=download` 的 `user_id` 只能从 `uinfo.uk` 取，多一跳且文档未在正文强调

### ⚠️ 矛盾 3：单步上传是否可用

[单步上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E5%8D%95%E6%AD%A5%E4%B8%8A%E4%BC%A0/) 正文同时说"一次请求即可完成"和"**通用上传场景建议优先使用分片上传流程**""此接口可能存在能力限制"。

**裁决**：**不使用**。统一走 precreate → superfile2 → create；小文件自然退化为单片，无需特例分支。

### ⚠️ 矛盾 4：分片大小是否恒定 4MB

| 来源 | 口径 |
| --- | --- |
| [分片上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E5%88%86%E7%89%87%E4%B8%8A%E4%BC%A0/) | 普通用户**固定 4MB**；会员 16MB；SVIP 32MB |
| 错误码 `31364` | 同上口径（超出分片大小限制，按用户身份） |
| [查询文件信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%9F%A5%E8%AF%A2%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/) | `block_list`「**按 4 MB 分片**」 |
| [能力说明](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E8%83%BD%E5%8A%9B%E8%AF%B4%E6%98%8E/) | **只给大小上限 4/10/20 GB + 分片数 ≤1024，压根没提分片大小** |
| [预上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%9B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E9%A2%84%E4%B8%8A%E4%BC%A0/) | 注意事项只说「文件大于 4 MB 时需本地切分」 |

**裁决**：**按 `vip_type` 动态取**（4/16/32 MB）。

> ⚠️ **证据强度说明**：`4MB/16MB/32MB` 这组数值**只出现在《分片上传》页面与错误码 `31364`**，能力说明页并未复述。第三方开源实现（`gitee.com/hefy27/pan-client`，Apache-2.0）的常量与此完全吻合（`DefaultSliceSize=4MB` / `VipSliceSize=16MB` / `SVipSliceSize=32MB` / `FirstSliceSize=256KB` / `MaxSliceNum=2048`），可作旁证。
> 📌 **该库的 `MaxSliceNum=2048` 与官方 `1024` 冲突 → 一律以官方 `1024` 为准。**
> ⚠️ `filemetas` 的 `blocks=1` 返回的 `block_list` **恒为 4MB 粒度**，**不能用于校验我们自己的分片**（SVIP 用户会看到不一致），只作参考。

### ⚠️ 矛盾 5：部分字段的 wire type 文档自相矛盾

| 接口 | 字段 | 参数表写 | 枚举 / JSON 示例 | 裁决 |
| --- | --- | --- | --- | --- |
| `categorylist` | `desc` | `string` | `0` / `1`（整数） | **按整数解析**，同时容忍字符串 |
| `unisearch` | `category`（响应） | `string` | 数值 | 按数值解析 |

**裁决**：解析时用**宽松解码**（整数/字符串都接受），不要硬 cast。

### ⚠️ 矛盾 6：文档示例与参数表打架

| 接口 | 现象 |
| --- | --- |
| `search` | 线上旧请求示例带 `page=1`，参数表**未定义** `page`；参数表说 `num` 默认 500 不可改，示例却用 `num=2` |
| `unisearch` | 参数表要求 `data` **必填且标注非空校验**，请求示例却传空对象 `{}` |
| `listall` | 参数表 `limit` 上限 10000，注意事项又说「建议不超过 1000」 |

**裁决**：以**参数表**为准，示例只作参考；`page` 不写入实现。`listall` 取 1000（更保守，且规避频控）。

### ⚠️ 矛盾 7：错误响应中 `errno` 的官方文档标 String 而实际为 int

| 来源 | 描述 |
| --- | --- |
| [错误码](https://pan.baidu.com/union/doc/%E5%B9%B3%E5%8F%B0%E7%AE%80%E4%BB%8B/%E9%94%99%E8%AF%AF%E7%A0%81/)「错误码格式表」 | `errno` 类型标 `String` |
| 同一页「例如」响应 | `{"errno": -6, "errmsg": "Invalid Bduss", "request_id": "..."}` —— `errno` 是负整数 |
| 所有业务接口的请求示例 | 响应中 `errno` 一律是 `int`（如 `0` / `31024`） |

**裁决**：**`errno` 按 `Int` 解析**。Swift 实现 `Int64` 即可覆盖所有已知码。若误按 `String` 解码，比较时（`errno == 0`）会类型不匹配。

> ⚠️ 同样的「文档 String/实际 int」问题在官方错误码页的 `request_id` 也存在：文档说 `String`，实际接口示例中为不带引号的 `uint64`。

---

## 10. 硬约束速查

| # | 约束 | 值 |
| --- | --- | --- |
| 1 | 目录围栏 | `/apps/{appname}`，越界 `20020` |
| 2 | 分片数量 | **≤ 1024** |
| 3 | 普通用户 | 4 MB/片，4 GB/文件 |
| 4 | 普通会员 | 16 MB/片，10 GB/文件 |
| 5 | 超级会员 | 32 MB/片，20 GB/文件 |
| 6 | 单步上传 | ≤ 2 GB（**不使用**） |
| 7 | User-Agent | `pan.baidu.com`，**所有请求** |
| 8 | dlink 有效期 | 8 小时 |
| 9 | 上传域名有效期 | **60 秒** |
| 10 | access_token | 30 天 |
| 11 | refresh_token | 一次性，10 年 |
| 12 | 未审核配额 | 10 次/小时，10 用户 |
| 13 | `list` 分页 | 无 `has_more`，靠 `count < limit` |
| 14 | 批量接口 | 顶层 errno=0 **不代表**子项全成功 |
| 15 | 普通用户限制 | 无法上传视频 / Live Photo |
| 16 | `filelist` | 英文半角引号合法 JSON |
| 17 | `fsids` 批量 | ≤ 100 个 |
| 18 | 删除语义 | 移入回收站（10 天 / SVIP 180 天） |
| 19 | `quota` 路径 | `/api/quota`，**不在 `/rest/2.0/xpan/` 下** |
| 28 | `categoryinfo` 路径 | `/api/categoryinfo`，**同样无 `method` 参数** |
| 29 | `info` 字段 wire type | **两种**：`list`/`imagelist`/`filemetas` 是数组；`categoryinfo` 是 **object（字典）** |
| 30 | `imagelist` 族分页 | 用 `page` + `num`；**不传 `page` 就不分页**（与 `list` 的 `start`+`limit` 不同） |
| 31 | `imagelist` 缩略图 | **仅 `web=1` 返回** `thumbs`；地址过期需重新请求 |
| 32 | 目录类接口参数名 | `list` 用 `dir`；`imagelist` 族用 **`parent_path`** |
| 20 | `vip_type` 来源 | **只能**取自 `uinfo`；`iotqueryuinfo` 无此字段 |
| 21 | `listall` 频控 | ≤ 8–10 次/分钟，超限 `31034` |
| 22 | `listall` / `categorylist` 翻页 | 必须回传响应里的 `cursor` 作 `start`，**禁止累加步长** |
| 23 | `expire` 同名三义 | `quota`=bool / `locateupload`=60秒 / token=有效期秒数 |
| 24 | 错误字段名不统一 | `errno/errmsg` 为主；`iotqueryuinfo`=`error_code/error_msg`；`unisearch`=`error_no/newno` |
| 25 | `create` 的 `rtype` | 创建文件 `0/1/3`；**创建文件夹只有 `0/1`**，无覆盖 |
| 26 | 创建文件夹 | 不得传 `size` / `block_list` / `uploadid` |
| 27 | `search` 关键字长度 | ≤ 30 个 UTF-8 字符 |

---

## 11. 错误码全表

> 📅 **官方更新时间：2026-08-13**。本表已按官方 [平台简介 > 错误码](https://pan.baidu.com/union/doc/%E5%B9%B3%E5%8F%B0%E7%AE%80%E4%BB%8B/%E9%94%99%E8%AF%AF%E7%A0%81/) 逐码核对，**54 个码 + 授权登录另表**（共 100+ 错误码场景）。
>
> 🚨 **官方错误码页文档错误**：「错误码格式表」将 `errno` 标为 `String`，但所有业务接口示例响应 `errno` 均为数字（如 `-6`）。**实施时按 `Int` 解析**，若实现误按 String 解码，错误判定会全错。

### 11.1 错误响应格式

```json
{
  "errno": -6,
  "errmsg": "Invalid Bduss",
  "request_id": "8889392513333350895"
}
```

| 参数 | 官方类型 | 实际 wire type | 说明 |
| --- | --- | --- | --- |
| `errno` | String ⚠️ | **int** | 具体错误码 |
| `errmsg` | String | string | 错误描述 |
| `request_id` | String | string / uint64（按接口） | 请求唯一标识 |

### 11.2 错误码须知（官方原文 4 条）

1. **一个错误码数字未必对应一个接口**——业务多，可能存在同一个错误码数字被用在多个业务中
2. **一个错误码未必是固定一种原因**——具体问题具体分析
3. 每个接口下也会有一些错误码提示，可参考
4. 如果是偶现出现的错误，**建议重试**

### 11.3 公共错误码（54 条，按官方顺序）

| 错误码 | 描述（官方） | 排查方向 / 处理建议 |
| --- | --- | --- |
| `-1` | 权益已过期 | 权益已过期 |
| `-3` | 文件不存在 | 文件不存在 |
| `-6` | **身份验证失败** | 1.access_token 是否有效；2.授权是否成功；3.接入授权 FAQ；4.接入授权章节 |
| `-7` | 文件或目录名错误或无权访问 | 文件或目录名有误 |
| `-8` | 文件或目录已存在 | — |
| `-9` | 文件或目录不存在 | — |
| `0` | 请求成功 | — |
| `2` | 参数错误 | 1.必选参数是否都已填写；2.参数位置（url 里还是 body 里）；3.参数值是否正确 |
| `6` | 不允许接入用户数据 | **10 分钟后再授权重试** |
| `10` | 转存文件已经存在 | — |
| `11` | 用户不存在（uid 不存在） | — |
| `12` | 批量转存出错 | 检查转存源和目的是不是同一个 uid（正常不应是一个 uid） |
| `111` | 有其他异步任务正在执行 | 稍后可重新请求 |
| `133` | 播放广告 | 稍后可重新请求 |
| `255` | 转存数量太多 | — |
| `2131` | 该分享不存在 | 检查 tag 是否传的空文件夹 |
| `20011` | 应用审核中，仅限前 10 个完成 OAuth 授权的用户测试应用 | **完成应用上线审核**，可放开用户数限制 |
| `20012` | 访问超限，调用次数已达上限，触发限流 | 1.完成应用上线审核；2.检查调用频率 |
| `20013` | 权限不足，当前应用无接口权限 | 1.完成应用上线审核；2.上线审核时是否申请该权限；3.重新发起审核 |
| `20015` | **该应用已失效，暂不支持访问** | 检查应用是否已删除 |
| `20016` | access_token 已过期 | 重新获取 token 或续期 |
| `20017` | access_token 无效 | 用户解绑或授权撤销，重新获取或续期 |
| `20020` | 路径不在允许的访问范围内 | 检查接口访问路径（**围栏越界**） |
| `20021` | 无法获取应用名称 | 检查应用 id 是否准确 |
| `20022` | 路径参数格式不正确 | 按接口文档示例传参，注意参数类型和格式 |
| `20023` | 缺少必需的路径参数 | 接口需要路径参数，不要漏传 |
| `31023` | 参数错误 | 同 `2` |
| `31024` | **没有访问权限 / 没有申请上传权限** | 控制台开通上传权限 |
| `31034` | **命中接口频控** | 接口请求过于频繁，控制调用 |
| `31045` | access_token 验证未通过 | 检查 access_token 是否过期、用户授权时是否勾选网盘权限 |
| `31061` | 文件已存在 | — |
| `31062` | 文件名无效 | 检查是否包含特殊字符 |
| `31064` | 上传路径错误 | 上传绝对路径必须 `/apps/<产品名>`；见能力说明「目录限制」 |
| `31066` | 文件名不存在 | 排查文件是否存储，路径是否传错 |
| `31190` | **文件不存在（分片/size 不一致）** | 1.block_list 参数是否正确；2.一般分片上传阶段有问题；3.分片传完了么；4.size 与实际文件及 precreate 的 size 一致性；5.对照文档逐步骤核参数 |
| `31299` | 第一个分片的大小小于 4 MB | 要等于 4 MB（首片硬约束） |
| `31301` | 非音视频文件 | 仅音视频处理接口 |
| `31304` | 视频格式不支持播放 | — |
| `31326` | **命中防盗链** | 检查 User-Agent 是否为 `pan.baidu.com` |
| `31338` | 当前视频码率太高暂不支持流畅播放 | 用户下载后播放 |
| `31339` | 非法媒体文件 | 检查视频内容 |
| `31341` | 视频正在转码 | 可重新请求 |
| `31346` | 视频转码失败 | 检查文件是否正常的视频 |
| `31347` | 当前视频太长，暂不支持在线播放 | 用户下载后播放 |
| `31355` | 参数异常（uploadid） | 一般是 uploadid 与 precreate 下发的 uploadid 不一致 |
| `31360` | **url 过期（dlink 过期）** | **可重试**：重取 dlink |
| `31362` | **签名错误** | 检查链接地址是否完整（是否误重编码 query） |
| `31363` | **分片缺失** | 1.分片是否全部上传、是否正确；2.size 是否正确；3.逐步骤核参 |
| `31364` | 超出分片大小限制 | **建议以 4 MB 作为上限**（实际按 vip_type 浮动） |
| `31365` | 文件总大小超限 | 普通用户 4 MB/4 GB；会员 16 MB/10 GB；SVIP 32 MB/20 GB |
| `31649` | 字幕不存在 | — |
| `42202` | 文件个数超过相册容量上限 | — |
| `42203` | 相册不存在 | — |
| `42210` | 部分文件添加失败 | — |
| `42211` | 获取图片分辨率失败 | 可重试 |
| `42212` | 共享目录文件上传者信息查询失败 | 可重试 |
| `42213` | 共享目录鉴权失败 | 没有共享目录权限；**不可重试** |
| `42214` | 获取文件详情失败 | 可重试 |
| `42905` | 查询用户名失败 | 可重试 |
| `50002` | 播单 id 不存在 | 异常处理或获取正确的播单 id |

### 11.4 授权与登录相关错误码

**不在本页面列出**，详见官方授权 OpenAPI 错误码列表：<https://openauth.baidu.com/doc/appendix.html#_4-openapi%E9%94%99%E8%AF%AF%E7%A0%81%E5%88%97%E8%A1%A8>

典型场景：

| 场景 | 代表错误 |
| --- | --- |
| 设备码已用 / 失效 | `invalid_device_code` |
| refresh_token 失效 | `invalid refresh` → 需用户重新扫码授权（**非应用封禁**） |
| 用户取消授权 | 用户取消导致 error_code 出现 |
| scope 缺失 `netdisk` | 需重新授权时勾选网盘权限 |
| AppKey/SecretKey 错误 | `invalid client` |

> ⚠️ 设备码轮询换 token 时若 `error` 出现，**不要立即视为失败**，要按官方 FAQ 处理：`access_token pending` → 继续轮询；`access_token expired` → 重新申请设备码；`invalid refresh` → 用户重新扫码。

### 11.5 按场景分类的速查表

| 场景 | 关键码 | 处理 |
| --- | --- | --- |
| **应用/权限级** | `20011` / `20012` / `20013` / `20015` / `20016` / `20017` / `20020` / `20021` / `31024` / `31045` / `31034` | `.permissionDenied` / `.authenticationFailed` / 指数退避 |
| **业务级** | `-1` / `-3` / `-7` / `-8` / `-9` / `10` / `255` / `2131` / `31061` / `31062` / `31066` / `20022` / `20023` | `.notFound` / `.invalidOperation` |
| **上传专属** | `31190` / `31299` / `31355` / `31363` / `31364` / `31365` / `31064` / `31061` | `.invalidOperation` / `.serverError` |
| **下载专属** | `31326` / `31360` / `31362` | **31360 可重试**重取 dlink；31326 检查 UA；31362 检查签名 |
| **音视频** | `31301` / `31304` / `31338` / `31339` / `31341` / `31346` / `31347` / `31649` | 不影响本存储同步，关联分享/播放场景 |
| **转存/分享** | `10` / `11` / `12` / `255` / `2131` / `42213` | 不影响本存储同步，关联分享业务 |
| **相册** | `42202` / `42203` / `42210` | 不影响本存储同步 |
| **临时性可重试** | `111` / `133` / `6` / `42211` / `42212` / `42214` / `42905` | 指数退避；`6` 退 10 分钟 |

---

## 12. 合规边界（官方明文）

来自 [平台简介](https://pan.baidu.com/union/doc/) 页明文列出的**禁止行为**：

1. 侵犯用户数据隐私，未经授权或用户不明确知晓时违规下载、使用、传播用户网盘数据
2. 违规作弊、侵犯百度商业利益，如多人共享开发者账号 / 个人网盘账号及会员权益
3. **利用个人网盘账号进行企业建站、图床、搭建网盘迁移工具等产品行为**

---
## 13. 加密库兼容性分析

> 本节分析「CloudDrive 百度网盘后端 + Cryptomator 风格加密库（CryptoLib）」组合下，26 个接口在「密文对云端不可见」场景下的可用性。
>
> **加密模型假设**：
> 1. 用户把密文保险库放在 `/apps/{appname}` 下；密文树由若干不透明文件名组成
> 2. 同步引擎**本地维护「密文 ↔ 明文」映射**，云端无法识别任何明文含义
> 3. 文件内容整体上传，云端把每个加密容器看作一个独立不透明 blob；分片上传仍有效，但分片是密文分片不是明文分片
> 4. 远程 ETag 必须由 `fs_id + size + server_mtime` 合成，绝不能用服务器返回的 md5（§9 矛盾 1 已述）

### 13.1 26 接口加密场景兼容性总表

| # | 接口 | 加密场景 | 结论 | 说明 |
| --- | --- | --- | --- | --- |
| **A1** | 获取设备码 | ✅ 完整可用 | **实现** | OAuth 流程前置，与是否加密无关 |
| **A2** | 轮询换 access_token | ✅ 完整可用 | **实现** | 同上 |
| **A3** | 刷新 token | ✅ 完整可用 | **实现** | 同上 |
| **B1** | `method=uinfo` | ✅ 完整可用 | **实现** | 上传分片档位要靠 `vip_type`，与加密无关 |
| **B2** | `GET /api/quota` | ✅ 完整可用 | **实现** | 总/已用/剩余空间是用户级信息，与加密无关 |
| **B3** | `method=iotqueryuinfo` | ❌ 不适用 | **不实现** | 桌面软件应用拿不到 `device_id`；非加密原因，是端类型问题 |
| **C1** | `method=list` | ✅ 完整可用 | **实现** | 列目录返回的是密文路径条目（不透明文件名），同步引擎拿到后用本地解密映射处理 |
| **C2** | `method=meta` | ✅ 完整可用 | **实现** | 单文件元信息 + dlink 用于下载；`md5` 字段不可信，跳过；ETag 用 `fs_id + size + mtime` |
| **C3** | `method=filemetas`（按 path） | △ 限制可用 | 视场景 | 当同步引擎已经知道密文路径时可调；fs_id 优于 path 时用 C4 |
| **C4** | `method=filemetas`（按 fsids） | △ 限制可用 | 视场景 | 适合批量条件写后的 fs_id 校验；`fsids ≤ 100` |
| **C5** | `method=listall` | △ 限制可用 | **建议不用** | 递归展开对加密目录是低价值高代价（频控 8-10 次/分钟；返回的是密文名还要二次解密定位）；同步引擎自维护树 |
| **C6** | `method=categorylist` | ❌ 完全无意义 | **不实现** | 服务端按「扩展名 / 类型 / 分类」过滤，密文文件名不命中任何已知扩展名 |
| **C7** | `method=search`（关键词） | ❌ 完全无意义 | **不实现** | 服务端按文件名关键字搜索；密文文件名不可读 |
| **C8** | `method=unisearch`（语义） | ❌ 完全无意义 | **不实现** | 同上，且语义检索依赖内容向量，密文无法生成明文向量 |
| **C9** | `method=imagelist`（图片列表） | ❌ 完全无意义 | **不实现** | 服务端按**真实扩展名**筛图片；密文文件名无扩展名，恒返回空 |
| **C10** | `GET /api/categoryinfo`（分类计数） | ❌ 完全无意义 | **不实现** | 同 C9；且密文场景无人关心「图片有几个」 |
| **C11** | `method=doclist`（文档列表） | ❌ 完全无意义 | **不实现** | 同 C9 |
| **C12** | `method=videolist`（视频列表） | ❌ 完全无意义 | **不实现** | 同 C9；且普通用户本就无法上传视频 |
| **C13** | `method=btlist`（BT 列表） | ❌ 完全无意义 | **不实现** | 同 C9；普通用户不支持创建 BT 任务 |
| **D1** | 下载 dlink | △ 限制可用 | **实现** | 完整下载无限制；`Range` 头只能按「**密文 blob**」的字节偏移切，**不能**按明文偏移。**首次下载必须整文件**；已知密文 size 后再追加下载可只用尾部 Range |
| **E0** | `method=locateupload` | ✅ 完整可用 | **实现** | 仅取上传域名，与内容无关 |
| **E1** | `method=precreate` | △ 限制可用 | **实现（不传密文衍生参数）** | 不传 `content-md5` / `slice-md5`（密文层面意义不大，服务器自己 hash）；仅传 `path/size/isdir/autoinit/rtype/block_list`。**`block_list` 用密文片 md5**，不是明文 |
| **E2** | `method=upload` | ✅ 完整可用 | **实现** | 上传密文分片，与分片内容无关 |
| **E3** | `method=create`（文件合并） | ✅ 完整可用 | **实现** | 合并密文分片，结果 fs_id 是密文 blob 的 id |
| **E4** | 单步上传 | ❌ 不用 | **不实现** | 官方不推荐；分片上限 2GB，普通用户超 4GB 文件无法走 |
| **创建文件夹** | `method=create`（`isdir=1`） | ✅ 完整可用 | **实现** | 与 E3 同端点；文件夹名同步引擎已加密处理 |
| **F1** | `method=filemanager` | ✅ 完整可用 | **实现** | copy/move/rename/delete 对不透明密文容器的操作，云端无需理解含义 |

### 13.2 实现清单（按必装程度分级）

| 实现优先级 | 接口 | 用途 |
| --- | --- | --- |
| **P0 必须** | A1/A2/A3 · B1 · B2 · E0 · E1 · E2 · E3 · 创建文件夹 · F1 · C1 · C2 | 12 个；缺一不可用 |
| **P1 强烈建议** | D1（含 Range 按密文尾段续传） · C3 / C4（fsids 校验回写） | 3 个；显著影响性能/正确性 |
| **P2 可选** | C5（仅在用户明确要求「按云端树对账」时启用，频控 8-10/min） | 1 个 |
| **不实现** | B3 · C5（如不启用 P2）· C6 · C7 · C8 · **C9–C13** · E4 | **11 个** |

### 13.3 加密场景下的关键限制

#### 13.3.1 文件内容接口

| 限制项 | 明文场景（参考） | 加密场景（实际情况） |
| --- | --- | --- |
| `meta.md5` / `list.md5` | 服务端说「可用于校验」（§9 矛盾 1） | 仍是服务端哈希，与密文不匹配；**禁止**作为内容校验依据 |
| `filemetas.blocks=1` 4MB 粒度 | 服务端哈希，与用户 4/16/32MB 分片一致 | 永远只是「4MB 一片」，无法用做 SVIP 32MB 分片的本地对齐校验（§9 矛盾 4） |
| `precreate` 秒传命中 | 服务端按 `block_list` 比对内容 | 服务端按密文片 md5 比对，秒传命中依然有效（前提是用户曾在**同一云端**上传过该密文 blob，**跨设备/跨账号迁移无效**） |
| `precreate.content-md5` / `slice-md5` | 用于秒传 | 加密上传**必须忽略这两个参数**：填了「整文件密文 MD5」会污染秒传、填了「前 256KB 明文 MD5」根本读不到明文 |
| `create.block_list` | 各分片 md5 | 用 E2 superfile2 返回的 md5（密文层），**不能**传本地算的密文 md5（与秒传判定不一致） |

#### 13.3.2 下载与分片

| 限制 | 明文场景 | 加密场景 |
| --- | --- | --- |
| Range 按字节偏移 | 任意位置取一段（如视频拖拽） | 只能取**密文 blob 字节范围**；且加密格式 header + chunks，不能从任意字节起始解密。**实际可用场景只有「整文件下载」与「从已知 size 处后下载尾部」** |
| `accept-ranges: bytes` | 服务端原生支持 | 服务端原生支持；但解密端**不能**用任意偏移 |
| `dlink` 8h 有效 | 缓存复用，命中 `31360` 重取 | 同上 |

#### 13.3.3 同步场景策略

| 同步场景 | 明文云盘实现 | 加密云盘实现 |
| --- | --- | --- |
| 初次同步（拉取） | `list` 列目录 → `meta` 拿 dlink → 整文件下载 → 解密 → 落盘 | 同左；解密在客户端 |
| 续传（云端 ↔ 本地） | 拿 `Range: bytes=N-end` 拉尾部 | **仅在「已下载部分 = 密文 blob 前 N 字节」**时可用 |
| 写入 | `precreate` 拿到 `block_list`（需要上传的分片序号）→ 上传 → `create` | 同步引擎**本地构造密文 blob**（包含 header + 密文 chunk 序列），然后做无 `content-md5` 的 `precreate`，按 `block_list` 上传密文分片，`create` 合并 |
| 移动 / 重命名 | `filemanager` `move` / `rename` | 同上；密文文件名就是 cloud 看到的字符串，移动/重命名天然兼容 |
| 删除 | `filemanager` `delete`（移入回收站） | 同上；加密场景**回退无法用回收站恢复明文**——用户教育性提醒，不是接口限制 |
| 列表去重 / 同步对比 | 用 `fs_id + size + mtime` 对比本地映射 | 完全相同；`md5` 一律不参与 |

#### 13.3.4 频控与降级

| 接口 | 频控阈值 | 加密场景的处理 |
| --- | --- | --- |
| C1 `list` | 1000 条/页；多页循环 | 单页 1000 上限与是否加密无关；分页靠 `count < limit` 判定 |
| C2 `meta` | 无明确频控 | 单次调用 |
| C5 `listall` | **8-10 次/分钟**（§10 约束 21） | 加密场景建议直接不用；列密文树效率低 |
| `categorylist` | 「**频控：一分钟后再试**」（官方原文） | 直接禁用 |
| E1/E2/E3 | 多文件并行上传时 QPS 提升触发 `31034` | 用并发池（3-32）控制，跨文件排队 |

#### 13.3.5 文件管理（操作不透明容器）

`filemanager` 4 种 opera 均对密文 blob 透明生效：

- **copy**：云端复制一个不透明容器，副本 `fs_id` 不同；同步引擎需更新本地映射
- **move / rename**：云端把不透明容器换位 / 改名
- **delete**：移入回收站；用户必须知道「回收站里仍是密文，不可还原」

#### 13.3.6 顺序与幂等性要求

加密场景下，**同步引擎必须有「密文路径 ↔ 明文路径」双向映射表**：

1. 同步引擎发起 `move` 时，明文路径变了 → 推算出对应的旧/新密文路径 → 调 `filemanager.move` 操作云端密文
2. 同步引擎写入新文件 → 推算出明文路径对应的密文路径 → 调 precreate/create
3. 同步引擎读远端 → 拿 `list` 返回的密文条目 → 在映射表查明文 → 在本地解密

这把加密的实现复杂度从「云端协议」隔离出来，全部收拢在同步引擎内；本客户端与百度网盘的契约层只为「不透明容器搬运」负责。

### 13.4 误区清单（加密场景下常见错误认知）

| # | 误区 | 真相 |
| --- | --- | --- |
| 1 | 「服务器返回的 md5 可以用来校验明文内容」 | **不可以**。服务器返回的是云端哈希，与明文不一致 |
| 2 | 「用 `listall` 拉完整棵云端树做同步」 | 不建议。密文目录递归列出意义小，且接口频控 8-10/min；同步引擎本地维护密文树 |
| 3 | 「用 `search` 找保险库里某个文件」 | 服务端搜不到；只在客户端本地搜解密后的明文 |
| 4 | 「Range 下载可以只拉缺失尾部」 | 仅当「已下载的就是密文 blob 前 N 字节」时可用；密文格式固定偏移含义时不能 |
| 5 | 「用 `download` 多一跳接口拿 dlink」 | 该接口需 `user_id`；我们用 `meta&dlink=1` 即可 |
| 6 | 「单步上传更简单」 | 不实用；分片上限 2GB，且官方不推荐 |
| 7 | 「precreate 时给 `content-md5` 加速秒传」 | 加密场景下没有意义，反而污染秒传判定；省略即可 |
| 8 | 「iotqueryuinfo 也算 VIP 来源」 | 仅 IoT 设备用；桌面端拿不到 `device_id` |
| 9 | 「categorylist 能筛 doc / image」 | 服务端按密文扩展名筛不命中任何已知分类 |
| 10 | 「下载失败后靠 `meta.md5` 重试判相同」 | 错误用 md5；ETag 必须用 `fs_id + size + mtime` |
| 11 | 「可以用 `imagelist` / `videolist` 让云端帮我分类」 | 密文无扩展名，服务端分类恒为空；这 5 个接口在加密场景全是死路 |
| 12 | 「`info` 字段一律当数组解」 | `categoryinfo` 的 `info` 是 **object**，共用数组解码会拿到空结果 |

---

## 14. 参考链接

- [平台简介](https://pan.baidu.com/union/doc/) · [错误码](https://pan.baidu.com/union/doc/%E5%B9%B3%E5%8F%B0%E7%AE%80%E4%BB%8B/%E9%94%99%E8%AF%AF%E7%A0%81/)
- [权限与配额](https://pan.baidu.com/union/doc/%E4%BD%BF%E7%94%A8%E5%85%A5%E9%97%A8/%E6%9D%83%E9%99%90%E4%B8%8E%E9%85%8D%E9%A2%9D/) · [SDK 概述](https://pan.baidu.com/union/doc/sdk/sdk-%E6%A6%82%E8%BF%B0/) · [平台使用规范](https://pan.baidu.com/union/protocol/)
- [设备码模式授权](https://pan.baidu.com/union/doc/%E4%BD%BF%E7%94%A8%E5%85%A5%E9%97%A8/%E6%8E%A5%E5%85%A5%E6%8E%88%E6%9D%83/%E8%AE%BE%E5%A4%87%E7%A0%81%E6%A8%A1%E5%BC%8F%E6%8E%88%E6%9D%83/) · [FAQ: access_token](https://pan.baidu.com/union/doc/faq/%E6%8E%A5%E5%85%A5access_token/) · [FAQ: 上传](https://pan.baidu.com/union/doc/faq/%E4%B8%8A%E4%BC%A0/)
- 上传：[能力说明](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E8%83%BD%E5%8A%9B%E8%AF%B4%E6%98%8E/) · [获取上传域名](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E8%8E%B7%E5%8F%96%E4%B8%8A%E4%BC%A0%E5%9F%9F%E5%90%8D/) · [预上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E9%A2%84%E4%B8%8A%E4%BC%A0/) · [分片上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E5%88%86%E7%89%87%E4%B8%8A%E4%BC%A0/) · [创建文件](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E5%88%9B%E5%BB%BA%E6%96%87%E4%BB%B6/) · [单步上传](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8A%E4%BC%A0/%E5%8D%95%E6%AD%A5%E4%B8%8A%E4%BC%A0/)
- 读取：[获取文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) · [递归获取文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E9%80%92%E5%BD%92%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) · [查询文件信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%9F%A5%E8%AF%A2%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/) · [获取分类文件列表](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E8%8E%B7%E5%8F%96%E5%88%86%E7%B1%BB%E6%96%87%E4%BB%B6%E5%88%97%E8%A1%A8/) · [搜索文件（关键词）](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%90%9C%E7%B4%A2%E6%96%87%E4%BB%B6%E5%85%B3%E9%94%AE%E8%AF%8D%E6%90%9C%E7%B4%A2/) · [搜索文件（语义）](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E6%96%87%E4%BB%B6%E4%BF%A1%E6%81%AF/%E6%90%9C%E7%B4%A2%E6%96%87%E4%BB%B6%E8%AF%AD%E4%B9%89%E6%90%9C%E7%B4%A2/)
- 管理：[创建文件夹](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E5%88%9B%E5%BB%BA%E6%96%87%E4%BB%B6%E5%A4%B9/) · [管理文件](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E7%AE%A1%E7%90%86%E6%96%87%E4%BB%B6/) · [下载](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E4%B8%8B%E8%BD%BD/)
- 用户与空间：[获取用户信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E7%94%A8%E6%88%B7%E4%BF%A1%E6%81%AF/%E8%8E%B7%E5%8F%96%E7%94%A8%E6%88%B7%E4%BF%A1%E6%81%AF/) · [查询用户身份信息及 VIP 权限](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E7%94%A8%E6%88%B7%E4%BF%A1%E6%81%AF/%E6%9F%A5%E8%AF%A2%E7%94%A8%E6%88%B7%E8%BA%AB%E4%BB%BD%E4%BF%A1%E6%81%AFAvip%E6%9D%83%E9%99%90/) · [获取网盘容量信息](https://pan.baidu.com/union/doc/%E5%9F%BA%E7%A1%80%E7%BD%91%E7%1B%98%E6%9C%8D%E5%8A%A1/%E8%8E%B7%E5%8F%96%E7%BD%91%E7%1B%98%E5%AE%B9%E9%87%8F%E4%BF%A1%E6%81%AF/)
- 控制台：[应用列表（提交上线审核）](https://pan.baidu.com/union/console/applist) · [上传调试工具](https://pan.baidu.com/union/devtool/upload)
