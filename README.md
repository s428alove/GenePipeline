---
title: "README"
author: "wei"
date: "2026-01-06"
output: html_document
---

```{r setup, include=FALSE}
knitr::opts_chunk$set(echo = TRUE)
```
See: CONTRACT.md

# MyPipeline

A modular R-based pipeline for GEO gene expression analysis.

This project provides a structured workflow to process GEO Series Matrix
files into standardized gene-level expression matrices, and to generate
dataset-level visualizations and downstream analyses.

---

## Project Concept

The pipeline is divided into two clearly separated layers:

- **V0_data_ingest**: data preparation and standardization
- **V1_analysis**: visualization and analysis

V0 produces clean, reusable data.
V1 consumes V0 outputs to generate figures and results.

---

## Pipeline Overview

### V0: Data Ingestion (Required)

Purpose:
- Convert GEO Series Matrix files into a standardized
  `gene × sample` expression matrix
- Ensure consistent log2 scale and gene identifiers

Input:
- GEO Series Matrix file
- Platform annotation (GPL)
- Sample metadata (group / batch)

Output:
- `expression_gene_log.tsv`
- `sample_metadata.tsv`
- `V0_summary.txt`

V0 does **not**:
- Perform differential expression analysis
- Generate figures
- Compare datasets

---

### V1: Analysis and Visualization

V1 is divided into two functional stages.

#### V1-A: Dataset-level Visualization (Fig2–Fig4)

Purpose:
- Provide quality control and overview of each dataset

Includes:
- Fig2: sample and metadata overview
- Fig3: expression distribution (boxplot / violin)
- Fig4: clustering, PCA, or heatmap

Each dataset is visualized independently.

---

#### V1-B: Differential and Integrated Analysis (Fig5–Fig7)

Purpose:
- Identify differentially expressed genes
- Compare results across datasets
- Perform meta-analysis

Includes:
- DEG analysis
- Intersection analysis
- Forest plots and summary figures

---

## Directory Structure

```text
MyPipeline/
├── datasets/
│   └── GSEXXXX/
│       ├── raw/
│       ├── metadata/
│       ├── V0/
│       └── V1/
├── V0_data_ingest/
├── V1_analysis/
├── figures/
├── results/
└── utils/

---

## Architecture

- CONTRACT.md — data schema and file structure
- POLICY.md — execution and validation rules
- DECISION_ARCHITECTURE.md — decision logic and inclusion resolution