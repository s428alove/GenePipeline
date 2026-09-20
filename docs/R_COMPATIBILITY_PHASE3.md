# Phase 3：R Compatibility Validation

本階段把「R 可以啟動」、「package environment Ready」與「R patch 已經有 GenePipeline evidence」分成三個狀態。Phase 3 沒有新增 renv project、沒有重建 `renv.lock`，也沒有更改 V0、Decision 或 V1 的分析演算法。

## Compatibility policy v1

政策 registry 位於 [`r-compatibility.json`](../decision_ui/api/runtime/r-compatibility.json)，判定程式位於 [`r-compatibility.js`](../decision_ui/api/runtime/r-compatibility.js)。Validated entry 的 committed evidence 是 Windows CI workflow；本機 runner 產生的 `localEvidence` 位於 Git-ignore 的 `tmp/compatibility/<version>/suite.json`。目前 Windows policy 是：

| 狀態 | R 版本 | 行為 |
| --- | --- | --- |
| validated | 4.5.2、4.5.3 | 可自動選擇；正常使用。兩者都必須有獨立 suite evidence。 |
| unvalidated | 高於 4.5 line、但未列入 registry | Best-effort；清楚 warning；不標示 supported／validated。失敗時建議安裝 validated 4.5.2／4.5.3。 |
| unsupported | 低於 4.5、無法辨識版本、非 Windows policy | 停止，不進 package environment。 |
| incompatible | registry 明確列出的版本 | 停止，回報 registry 原因。 |

Selection 先在 installed、實際 probe 成功的候選中選最高 validated patch；沒有 validated 時，才選最高允許的 unvalidated 候選。它不會把任意可執行 R 當成 supported，也不會因新版存在而要求移除新版或手動指定 Rscript。

Runtime response 的 `compatibility.status` 不等同於 `detected` 或 `package environment ready`。Unvalidated R 的 API 會附帶 warning；unsupported／incompatible 會在 `r_compatibility` stage 以 `R_UNSUPPORTED`／`R_INCOMPATIBLE` 停止。

## Frozen fixture

[`tests/fixtures/GSE10288`](../tests/fixtures/GSE10288) 是本階段的 repository fixture：

```text
tests/fixtures/GSE10288/
├── input/
│   ├── GSE10288_series_matrix.txt
│   └── GPL6426_family.soft
├── decision/
│   └── sample_metadata_decision.tsv
├── config/
│   ├── parameters.json
│   └── tolerance.json
├── expected/
│   ├── contracts.json
│   ├── expression_gene_log.tsv
│   ├── gene_missingness.tsv
│   └── topTable.tsv
└── checksums.json
```

測試開始與結束都驗證 checksum 與 file inventory；測試只複製 fixture 到隔離 project，不修改 source fixture。Fixture 包含 raw input、reviewed Decision、V0／V1 parameters、expected outputs、gene／sample contracts、significant ID set 及 SHA-256 integrity manifest。它只作為 change detector，不是把目前結果宣稱為不可改變的 biological truth。

Phase 3 v1 沒有建立 mapping provenance artifact，也沒有重新啟用舊 `GPL6426_probe2gene.tsv` cache。V0 compatibility 只驗證實際產生的 canonical outputs；如果未來發生 divergence，再另外診斷 mapping。

## Contracts and tolerance

[`tests/compatibility-contracts.js`](../tests/compatibility-contracts.js) 以 key 對齊資料，不依賴 row order：

- V0 gate 必須 passed、`canonical_expression_ready = true`，mapped／gene／sample summary 必須符合 fixture。
- `gene_missingness.tsv` 的 removed gene ID set、missing counts、action、reason 必須 exact；`missing_fraction` 做 numeric comparison。
- `expression_gene_log.tsv` 的 gene IDs、sample IDs、dimensions、唯一性、numeric／finite 及完整矩陣做 comparison。
- Decision 只驗 fixed fixture 能 load、save／merge／validate，且 cohort IDs 與 case／control counts 不變；不把人工決策當 biological golden truth。
- DEG `ID` set、row count、`logFC`、`P.Value`、`adj.P.Val`、`t`、`B` 做 numeric comparison；`Gene.symbol`、`Gene.title` 做字串／NA comparison。FDR 0.1、`|logFC|` 0.5 的 significant gene ID set 必須 exact。

Initial tolerance 是 absolute = 0、relative = 0。兩個實際 target 的量測結果：

| Contract | Compared values | Max absolute drift | Max relative drift |
| --- | ---: | ---: | ---: |
| V0 expression matrix | 11,684 | 0 | 0 |
| V0 missing fraction | 31 | 0 | 0 |
| V1 each DEG numeric field | 254 rows／field | 0 | 0 |

若日後出現差異，runner 會報告 V0 或 V1 contract 及欄位，不會自動更新 baseline 或放寬 tolerance。

## Validation runner and CI

本機執行單一 target：

```text
node tools/validate-r-compatibility.js 4.5.2
node tools/validate-r-compatibility.js 4.5.3 --r-bin <isolated-R-4.5.3-bin>
node tools/compare-r-compatibility.js
```

Runner 使用 Phase 2 的 isolated project、temporary server、package setup、Decision workflow 與 smoke runner；另以指定版本重新 probe R，避免只依賴 PATH 目前選到的版本。每個 target 會執行 Node tests、environment bootstrap／restore、V0、Decision、V1 full、thresholds-only、fixture integrity，產生 `tmp/compatibility/<version>/suite.json`、`report.json`、outputs 與 TAP evidence。

Windows matrix 位於 [`.github/workflows/r-compatibility.yml`](../.github/workflows/r-compatibility.yml)，target 為 R 4.5.2 與 R 4.5.3。每個 job 先使用 `r-lib/actions/setup-r@v2` 安裝指定 R，再執行相同 runner；第二個 job 讀兩個 target artifacts，做 cross-patch drift comparison。R 4.6.x 不在本階段 required matrix，仍會依 registry 的 unvalidated best-effort policy 運作。

## 實際結果

- R 4.5.2：PASS；22 tests、0 failure、0 skip；environment bootstrap／restore PASS；frozen workflow PASS。
- R 4.5.3：PASS；22 tests、0 failure、0 skip；environment bootstrap／restore PASS；frozen workflow PASS。
- cross-patch：V0 matrix、missingness、DEG numeric fields 均 exact match；significant ID set exact match（27 genes）。
- fixture source 在執行前後 checksum 不變；Decision source 未被測試修改。
- 4.5.3 使用隔離 R 安裝目錄完成實測；這個本機安裝物不屬於 repository，也不會被提交。

## 本階段限制

本階段沒有做 R 4.6 正式 validation、macOS／Linux、clean-machine、offline package mirror、installer、Node executable、mapping provenance redesign 或 frontend redesign。R 4.5.2／4.5.3 的 evidence 依目前 Windows、Node 22.18.0、同一 `renv.lock` 與 Bioconductor 3.22 建立；它們是目前 validated patches，不代表所有 future package source 或硬體組合都已驗證。
