# 🧬 V1 Analysis --- README

## 🎯 Purpose

V1_analysis is the execution layer that performs:

-   QC (analysis-level)
-   Differential Expression (DEG)
-   Interpretation (future)
-   Enrichment (future)

It consumes **resolved inputs only** and produces **analysis outputs +
evidence**.

------------------------------------------------------------------------

## 🧭 Core Principle

> V1 uses decisions --- it does NOT make decisions.

------------------------------------------------------------------------

## 📥 Inputs (Canonical)

From CONTRACT:

-   expression:\
    data_processed/`<GSE>`{=html}/expression_gene_log.tsv

-   metadata:\
    data_processed/`<GSE>`{=html}/sample_metadata_merged.tsv

These are the **only allowed inputs**. fileciteturn2file1L94-L113

------------------------------------------------------------------------

## ⚠️ Input Assumptions

Before running V1:

-   include 已經決定
-   group_label 完整
-   case_control（若 DEG）已定義
-   dataset 已通過 decision gate

------------------------------------------------------------------------

## 🔁 Pipeline Position

V0 → Decision Layer → **V1_analysis**

------------------------------------------------------------------------

## ⚙️ Modules

### 1️⃣ Input Validation

Script: - \_lib/validate_inputs.R

責任： - file 存在 - schema 正確 - sample alignment - include 合法 -
grouping 合法

符合 CONTRACT validation 規範 fileciteturn2file1L136-L144

------------------------------------------------------------------------

### 2️⃣ QC Dataset Overview

Script: - 01_qc_dataset_overview.R

產出： - PCA - sample distance heatmap - boxplot - QC summary

📌 規則：

QC = evidence only\
不得修改 include fileciteturn2file0L11-L17

------------------------------------------------------------------------

### 3️⃣ Differential Expression

Script: - 02_run_differential_expression.R

方法： - limma

條件： - 僅支援 2 groups fileciteturn2file0L9-L13

輸出： - deg_table.tsv - deg_summary.txt

------------------------------------------------------------------------

### 4️⃣ Interpretation（未來）

------------------------------------------------------------------------

### 5️⃣ Enrichment（未來）

------------------------------------------------------------------------

## 🔁 Feedback Loop（關鍵）

V1 不修改 decision，但會產生 review evidence：

V1 QC → 人工/ UI review → 修改 decision → 重跑 Decision → 重跑 V1

------------------------------------------------------------------------

## 🚫 非責任

V1 不應：

-   修改 include
-   修改 metadata
-   做 decision
-   自動排除樣本

------------------------------------------------------------------------

## 📦 Output Philosophy

所有輸出：

-   可重現
-   可追蹤
-   與 decision 分離

------------------------------------------------------------------------

## 🧭 Summary

Decision Layer → WHAT\
V1_analysis → HOW
