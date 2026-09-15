# Phase 2：R Package Environment Reproducibility

本階段在 `phase2-renv` 建立單一 repository-level renv environment。未改動 Phase 1 R discovery／selection、Decision semantics、V0 資料處理、V1 QC／DEG 演算法或 frontend。修改保留供 review，未 commit、push、merge。

## 修改檔案與用途

| 檔案 | 用途 |
| --- | --- |
| `DESCRIPTION` | `Imports` 定義 11 個直接分析依賴；`Suggests` 定義環境工具；集中 CRAN、Bioconductor release、renv pin。 |
| `renv.lock` | 實際 snapshot／restore 產生的完整版本與來源紀錄，共 48 個 package records。 |
| `renv/settings.json` | explicit snapshot、Bioconductor release、project library 設定。 |
| `renv/activate.R` | renv 產生的標準 autoloader；應用程式分析入口刻意不呼叫它，以避免隱含 bootstrap。 |
| `renv/.gitignore` | renv 產生的本機 library 排除規則。 |
| `.Rprofile` | 呼叫 installation-free 的共用 activation／readiness 檢查。 |
| `tools/r-environment-lib.R` | 中央定義讀取、activation、bootstrap、restore、同步與 loadability 檢查、結構化診斷。 |
| `tools/r-environment.R` | 使用 clean R process 執行 check／setup 的 CLI protocol。 |
| `decision_ui/api/runtime/package-environment.js` | Node setup supervisor、狀態、log、setup lock、R subprocess 與 analysis profile 設定。 |
| `decision_ui/api/server.js` | 啟動自動 setup；R-backed routes 加入 package gate；新增環境 status／retry API；可注入隔離 project root 供 smoke 使用。 |
| `V0_data_ingest/00_setup_env.R` | 退休舊的獨立 installer，只回報改用 GenePipeline setup。 |
| `V0_data_ingest/99_run_V0.R` | 只修改缺少 jsonlite 的錯誤提示。 |
| `V1_analysis/_lib/manifest.R` | 只修改 jsonlite／digest 的錯誤提示。 |
| `V1_analysis/scripts/99_run_all.R` | 只修改 optparse 的錯誤提示。 |
| `V1_analysis/scripts/_tools/00_sanity_check_inputs.R` | 套件 readiness 與版本報告改讀中央定義；保留輸入檢查。 |
| `package.json`、`decision_ui/api/package.json` | 新增 package preflight、setup、smoke 指令。 |
| `tests/package-environment.test.js` | Ready、缺套件、缺 renv、bootstrap／restore failure、修復及分析阻擋測試。 |
| `tests/environment-fixture.js` | 隔離測試環境、library／cache junction 與限定範圍 cleanup。 |
| `tests/server.test.js` | 使用真實中央 package preflight；啟動測試等待 Ready；不再因原 global library 缺套件而 skip。 |
| `tools/smoke-environment.js` | 隔離資料的首次 setup、完整分析 smoke，以及版本正確但損壞套件的實際修復測試。 |
| `tools/create-environment-lock.R` | 維護者使用的依賴解析、安裝與 explicit snapshot。啟動不會呼叫。 |
| `tools/create-environment-lock.js` | 維護者 lock 建立入口；加做 fresh restore／snapshot roundtrip 與根環境驗證。 |
| `.gitignore` | 排除 library、cache、bootstrap、setup logs、lock 與 smoke 產物。 |
| `README.md`、本文件 | 取代人工 R package 安裝指示，說明新架構、診斷與驗證結果。 |

## 最終 environment architecture

```text
Launcher → Node server
             ↓
       Phase 1 R discovery / real version probe (--vanilla)
             ↓
       Package check (--vanilla，明確載入共用 helper)
             ├─ Ready → 不 restore、不 reinstall
             └─ Not Ready → setup lock → bootstrap renv → restore → fresh-process check
                                                                      ↓
                                                                    Ready

Analysis request → R preflight → package preflight → Rscript + root .Rprofile → analysis
```

R runtime 與 package environment 是兩種獨立狀態。Phase 1 probe 不載入 renv；分析使用 Node 指定的 root `R_PROFILE_USER`，不採用任意 user profile。所有分析 subprocess 的 working directory 是 project root。

Setup 只在啟動、明確 retry API 或 setup CLI 執行。分析 request 不呼叫 setup、不安裝套件、不 snapshot。`.Rprofile` 只載入已安裝的 pinned renv 並檢查 readiness，沒有 source 標準 `renv/activate.R`。直接以 `Rscript --vanilla` 執行分析會略過 profile，不是應用程式提供的分析入口。

同一 Node process 的 setup 共用 Promise；跨 process 以 `renv/.setup.lock` 防止重疊 setup。只有已確認 PID 不存在的 lock 才在下次 setup 回收。Setup 期間分析回傳 Not Ready。進度寫至 console 與 `logs/environment/setup-*.log`，可由 `GET /api/environment` 查詢；`POST /api/environment/setup` 明確重試，回傳 202。未更動 UI。

## Dependency source of truth

`DESCRIPTION: Imports` 是直接分析依賴的唯一清單：optparse、readr、dplyr、stringr、tibble、tidyr、jsonlite、ggplot2、pheatmap、digest，以及 Bioconductor 的 limma。Setup、preflight、V1 sanity check 與測試讀取此定義；README 引用定義，不再维护另一份手動安裝清單。

`Suggests` 的 renv、BiocManager 是環境工具，不是分析 runtime dependencies。GEOquery、Biobase 未加入直接依賴，也不是目前 lock 的 package records；其他套件的完整 metadata 中可能提到它們作為 optional dependencies。

`renv.lock` 負責實際版本、來源及 transitive dependencies。根 `renv/library` 是唯一分析 project library；`renv/bootstrap` 只提供啟動所需的 pinned renv，並非 V0／V1 各自的 environment。Library 路徑由 `renv::paths$library()` 決定，依 R series／platform 分層；cache、state 也位於 repository 的 renv 目錄並由 Git 排除。

## Bootstrap、restore 與 lockfile

本次驗證基準：Windows、Node 22.18.0、R 4.5.2、renv 1.1.5、Bioconductor 3.22。這是實際建立 lock 的環境，不是新的 R version compatibility policy。

缺少 renv 時，setup 從中央 CRAN URL 下載 pinned source archive；目前 contrib 不存在該版本時嘗試 Archive。安裝到 project bootstrap library 後確認版本與可載入性。安裝子程序使用專用 profile 設定，避免環境尚未建立時觸發分析 readiness gate。

一般 setup 使用 `renv::restore(prompt = FALSE, clean = TRUE)`。不會依使用者既有 global library 產生 lock；缺少 lock 時明確失敗。Restore 完成後，在另一個全新 R process 驗證，避免已載入 namespace／DLL 掩蓋錯誤。

本 lock 由實際安裝及 explicit snapshot 產生，再經隔離 project fresh restore／snapshot roundtrip 正規化。過程發現 Bioconductor binary 的來源 metadata 在 restore 後增加 `RemoteType`，造成同版本仍被 status 判為不同步；透過實際還原後 snapshot 解決，沒有手工捏造版本或跳過 status。

維護者更新環境時可執行 `node tools/create-environment-lock.js`，之後 review lock diff 並跑測試；此命令會解析／安裝依賴及修改 lock，絕不由正常 startup 執行。`--normalize` 僅對既有 lock 做 restore roundtrip，並驗證各 package version 未改變。

renv 1.1.5 對版本已一致的 library 可能直接略過 restore，即使指定 rebuild。故版本正確但不可載入時，setup 改在 staging library rebuild，成功後才替換原 library，失敗保留原 library；再由新 process 驗證。實際損壞 optparse 的修復 smoke 已通過。

## Ready 判定與 errors

以下條件全部成立才回報 Ready：

1. Project bootstrap renv 存在、版本符合中央 pin 並可載入。
2. `renv::project()` 是 repository root，`.libPaths()[1]` 是預期 project library。
3. Lock 可解析、含 R version、所有 direct／tooling records、正確 renv 與 Bioconductor pin；settings 使用 explicit snapshot 與指定 Bioconductor release。
4. 每一個 lock record 在 project library 中均有相同版本，沒有額外未鎖定的 package。
5. `renv::status(..., dev = TRUE)$synchronized` 為 TRUE，包含來源 metadata 的同步檢查。
6. 11 個 direct dependencies 均實際 `requireNamespace()` 成功，且載入位置對應 project library（允許 renv cache junction）。

| Code | 意義 |
| --- | --- |
| `R_NOT_AVAILABLE` | Phase 1 找不到可執行的 R；不開始 package setup。 |
| `PACKAGE_ENV_NOT_READY` | 未設定、設定中、缺 lock、activation 或同步條件不符。 |
| `RENV_BOOTSTRAP_FAILED` | pinned renv 下載／安裝／載入失敗。 |
| `RENV_RESTORE_FAILED` | lock restore／repair 執行失敗。 |
| `PACKAGE_VALIDATION_FAILED` | 套件不可載入或 package 檢查執行失敗。 |

R-backed API 的 package failure 使用 HTTP 503、`stage: package_environment`，並提供 status、package checks、mismatches 或執行診斷。既有各層 `library()`／`requireNamespace()` 保留為防禦性 runtime validation，不會自行安裝。

## Tests 與實際 smoke

`npm test`：**17 pass、0 fail、0 skip**。涵蓋：

| Case | 驗證與結果 |
| --- | --- |
| A：Ready | 真實 root environment active／synchronized，11 個 packages 可載入；另驗證 Ready startup 不呼叫 restore。PASS。 |
| B：缺套件 | 隔離 library 移除 optparse；preflight Not Ready，5 個 R-backed routes 回 503，未呼叫 setup 或安裝。PASS。 |
| C：缺 renv | 模擬 supervisor bootstrap event 與 setup 去重；真實無 renv check 不安裝；不可用 repository 回 bootstrap failure。另完整 smoke 實際下載安裝 renv。PASS。 |
| D：restore failure | 真實無效 lock restore 回 `RENV_RESTORE_FAILED`，保留診斷並釋放 setup lock。PASS。 |
| E：Phase 1／server | 原 R discovery、真實 version detection、no-R cases、server startup 與 Decision integration。PASS，無 skip。 |
| 修復 | 缺 optparse 真實 cache restore；版本正確但內容損壞先拒絕 Ready。獨立 repair smoke 真實 rebuild 後恢復 Ready。PASS。 |

`node tools/smoke-environment.js`：隔離 project 起初沒有 renv bootstrap 或 project library；共用既有 cache。經真實 bootstrap → restore → Ready，使用 GSE10288 資料及既有人工決策的複本完成：

- V0：PASS；沿用既有 reviewed missingness threshold 0.11，46 samples、285 genes 中移除 31，保留 254。
- Decision load／save／export-and-merge／validation：全部 PASS。
- V1 full run：PASS；25 Tumor case、21 Normal control。
- V1 thresholds-only rerun：PASS；FDR 0.1、absolute logFC 0.5，27 significant genes。
- 上述 7 次 API calls 全部 HTTP 200；原決策檔 bytes 未變更。

接著執行 `node tools/smoke-environment.js --repair-only tmp/phase2-smoke/demo-P04Uf0`：保留 optparse 的正確 DESCRIPTION 版本但移除可執行內容；preflight 拒絕，setup rebuild 後 fresh-process check synchronized／Ready，PASS。

本機完整結果位於 `tmp/phase2-smoke/demo-P04Uf0/smoke-report.json`，setup logs 與隔離分析輸出留在同一目錄供 review；這些產物由 Git 排除。`git diff --check` 通過。以上不是無 cache 的 clean-machine 安裝驗證，也不是逐項數值比對的統計 golden test。

## 尚未解決與 Phase 3 建議

- 首次下載與無 cache 的 repair 依賴外部 CRAN／Bioconductor 來源可用性；本輪未做 clean-machine、離線安裝、所有網路故障或 binary 消失的完整驗證。
- 尚未建立 supported R matrix；lock 的 R／Bioconductor 基準不應被解讀為所有可 discovery 的 R 版本都可成功 restore。
- Windows 安裝被中斷、setup timeout 的整棵子程序回收、多 server 與分析同時執行時的跨 process 協調，仍需後續 hardening。現有 setup lock 防重複 setup，但不是完整分析工作排程鎖。
- 本機部分 R 執行出現 `C.UTF-8` locale warning；本次 preflight、restore 與分析均成功，未在本階段更改 locale policy。
- 下一階段優先做乾淨 Windows 安裝驗證、支援版本 CI、套件來源長期保存／離線 cache 策略，再處理 Node executable／installer 與更完整 setup progress UI。這些皆未於本輪實作。

設計參考：[renv status](https://rstudio.github.io/renv/reference/status.html)、[renv restore](https://rstudio.github.io/renv/reference/restore.html)、[R Startup](https://stat.ethz.ch/R-manual/R-devel/library/base/html/Startup.html)。實作行為另以本案 pinned renv 1.1.5 的實際測試為準。
