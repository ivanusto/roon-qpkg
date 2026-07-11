# Roon Server QPKG for QNAP（Container Station 容器化套件）

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

以 [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg) 的架構，
把 [RoonLabs 官方 Docker 映像](https://github.com/RoonLabs/roon-docker)（`ghcr.io/roonlabs/roonserver`）
包裝成 QNAP App Center 可安裝的 QPKG。

**本套件只包含管理指令碼與狀態頁（UI 外殼），不內含任何 Roon 程式或映像檔。**
使用者在 App Center 點選安裝後，套件會在背景呼叫系統的容器引擎（Container Station 的 docker CLI）
下載官方映像並建立容器，安裝流程本身數秒即完成。

```
App Center 安裝 QPKG（僅指令碼 + 狀態頁，< 1 MB）
        │
        ▼
package_routines ──► 背景執行 docker pull ghcr.io/roonlabs/roonserver:latest
        │
        ▼
roon-server-docker.sh start ──► docker run --net=host -v <SSD>/RoonServer/data:/Roon ...
                          └───► busybox httpd 容器（埠 18630）服務狀態頁 UI
```

> 套件內部名稱為 `RoonServerDocker`（顯示為「Roon Server (Docker)」），
> 刻意與 QNAP Store 的「RoonServer」不同名——同名會讓 App Center
> 誤判為同一套件並強制以商店版本覆蓋更新。

## 系統需求

| 項目 | 需求 |
|---|---|
| NAS 架構 | **x86_64（amd64）**，官方 Roon 映像不支援 ARM |
| QTS | 5.0 以上 |
| 相依套件 | **Container Station 3.0+**（`QPKG_REQUIRE` 自動檢查） |
| 記憶體 | 建議 8 GB 以上（Roon 官方建議） |
| 儲存 | **強烈建議具備 SSD 儲存池**存放 Roon 資料庫 |

## 安裝

1. 從 [Releases](../../releases) 下載 `RoonServerDocker_x.y.z_x86_64.qpkg`。
2. （若曾安裝過舊版 1.0.0 的「RoonServer」套件，請先從 App Center 移除。）
3. App Center → 右上角「手動安裝」→ 選擇 qpkg 檔。套件未簽章，若 App Center 拒絕安裝，
   到「App Center → 設定 → 一般」允許安裝未經簽署的應用程式。
4. 安裝完成後，映像檔會於**背景**下載（視網速數分鐘），完成後容器自動建立並啟動。
   進度可查看 `<安裝目錄>/logs/pull.log`，或點 App Center／桌面圖示開啟狀態頁
   （`http://<NAS IP>:18630/`，由套件自帶的 busybox httpd 容器提供，
   **不需要**啟用 QTS「Web 伺服器」服務）。
5. 在同網段的電腦／平板開啟 [Roon App](https://roon.app/downloads)，會自動探索到 NAS 上的 Roon Server。

## 兩個關鍵設計

### 1. 網路強制採用 host 模式

Roon 依賴**區網多播／廣播**（RAAT 協定）探索串流播放裝置（Roon Ready、AirPlay、Chromecast）
與遙控器 App。bridge/NAT 網路會擋掉多播封包，**裝置探索與遙控功能會完全失效**。

因此 `roon-server-docker.sh` 把 `--net=host` 寫死，且**每次啟動都會檢查**容器的
`HostConfig.NetworkMode`；若曾被人從 Container Station UI 改掉，會自動以 host 模式重建容器
（Roon 資料庫不受影響）。`roon.conf` 的 `ROON_EXTRA_ARGS` 也無法覆蓋此設定。

### 2. 資料庫與快取必須放在 SSD 儲存池

Roon 資料庫（容器內 `/Roon`）充滿小型隨機讀寫。放在 HDD 磁碟區會造成音訊解碼不順、
播放清單／媒體庫載入緩慢、搜尋卡頓。套件以三種方式引導使用者：

- **啟動時偵測**：服務腳本以 `/sys/block/*/queue/rotational` 做 best-effort 判斷，
  若資料路徑位於旋轉式硬碟，寫入 QTS 系統事件（警告等級）並在狀態頁顯示醒目警示。
- **狀態頁教學**：套件網頁（App Center 點圖示開啟）內含逐步搬移教學。
- **設定檔註解**：`roon.conf` 內以大寫註解標明建議。

設定方式：

```sh
# SSH 登入 NAS，編輯 <QPKG 安裝目錄>/roon.conf
ROON_DATA_PATH="/share/CACHEDEV2_DATA/RoonServer/data"   # 指向 SSD 磁碟區

# 若要搬移既有資料庫：
/etc/init.d/roon-server-docker.sh stop
cp -a /share/CACHEDEV1_DATA/RoonServer/data/. /share/CACHEDEV2_DATA/RoonServer/data/
/etc/init.d/roon-server-docker.sh start
```

> 如何確認哪個磁碟區在 SSD 池：QTS「儲存與快照總管」→ 儲存空間，
> 看磁碟區所屬儲存池的成員硬碟類型（需為純 SSD 池，SSD「快取」不算）。

## 設定檔（roon.conf）

| 變數 | 預設 | 說明 |
|---|---|---|
| `ROON_IMAGE` | `ghcr.io/roonlabs/roonserver:latest` | 官方映像 |
| `ROON_DATA_PATH` | `<預設磁碟區>/RoonServer/data` | Roon 資料庫／快取 → 容器 `/Roon`，**請放 SSD** |
| `ROON_MUSIC_PATH` | `/share/Multimedia` | 音樂庫 → 容器 `/Music` |
| `ROON_BACKUP_PATH` | （空 = 不掛載） | 備份 → 容器 `/RoonBackups` |
| `ROON_TZ` | 自動偵測 QTS 時區 | IANA 時區名稱 |
| `ROON_STOP_TIMEOUT` | `120` | 停止時給資料庫的乾淨關閉秒數 |
| `ROON_UI_PORT` | `18630` | 狀態頁埠（App Center 圖示連結會自動跟隨） |
| `ROON_UI_IMAGE` | `busybox:stable` | 狀態頁的迷你 httpd 容器映像 |
| `ROON_EXTRA_ARGS` | （空） | 額外 `docker run` 參數（無法覆蓋網路模式） |

修改後執行 `/etc/init.d/roon-server-docker.sh restart` 或從 App Center 重啟套件。
設定檔在升級／重裝時會保留。

## 維運指令

```sh
/etc/init.d/roon-server-docker.sh status    # 狀態
/etc/init.d/roon-server-docker.sh restart   # 重啟
/etc/init.d/roon-server-docker.sh update    # 拉取新版官方映像並重建容器（資料庫保留）
/etc/init.d/roon-server-docker.sh pull      # 僅下載映像
```

移除套件時會刪除容器，但**保留** `ROON_DATA_PATH` 下的 Roon 資料庫，避免誤刪授權與聆聽紀錄。

## 從原始碼建置

```sh
# 需要 Docker（任何平台）
make            # 產出 build/RoonServerDocker_<版本>_x86_64.qpkg

# 或在 Ubuntu 上直接使用 QDK
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
cd <本專案> && qbuild --build-arch x86_64
```

GitHub Actions 會在每次 push 建置 qpkg 工件，推送 `v*` 標籤時自動發佈 Release。

## 專案結構

```
├── qpkg.cfg                  # QPKG 中繼資料（相依 Container Station、WebUI 位置）
├── package_routines          # 安裝/移除掛勾：背景 pull 映像、保留設定與資料庫
├── shared/
│   ├── roon-server-docker.sh # 服務腳本：找 docker CLI、強制 host 網路、SSD 偵測、狀態頁容器
│   ├── roon.conf.default     # 使用者設定範本
│   └── web/index.html        # 狀態頁／設定教學（UI 外殼，由 busybox httpd 容器服務）
├── icons/                    # App Center 圖示
├── x86_64/                   # qbuild 架構標記（套件本身為純腳本）
├── Dockerfile / Makefile     # QDK 建置環境
└── .github/workflows/        # CI：建置與 Release
```

## 疑難排解

| 症狀 | 原因與解法 |
|---|---|
| App Center 顯示「Roon Server 有更新」且強迫更新 | 你裝的是 1.0.0 舊版（內部名稱 `RoonServer` 與商店套件相同）。請移除舊版，改裝 1.1.0+（內部名稱 `RoonServerDocker`，不再衝突）。 |
| 顯示「沒有數位簽章」 | 本套件未經 QNAP 簽署，屬正常現象；於 App Center 設定允許未簽章應用程式即可。 |
| 點圖示打不開狀態頁 | 狀態頁由套件自帶的 busybox httpd 容器在埠 `18630` 提供；確認套件已啟動，或該埠被占用時改設 `ROON_UI_PORT` 後重啟。 |
| Roon App 找不到伺服器 | 確認容器為 host 網路（本套件每次啟動會自動修正）、NAS 與遙控裝置在同一網段，且映像已下載完成（看狀態頁或 `logs/pull.log`）。 |
| 映像檔下載卡住 | SSH 執行 `/etc/init.d/roon-server-docker.sh diag` 檢查 DNS／registry 連線與 pull 記錄；也可手動 `docker pull ghcr.io/roonlabs/roonserver:latest` 觀察錯誤，完成後 `restart`。狀態頁在下載期間會顯示即時進度（1.1.1+）。 |

## 授權與商標

管理指令碼以 MIT 授權。Roon 與 Roon Server 為 Roon Labs LLC 之產品，
其軟體與映像檔適用 Roon Labs 自身之授權條款。本專案與 Roon Labs、QNAP 皆無隸屬關係。
