-- ============================================================
-- ProcureIQ Dashboard — Athena KPI Queries Reference
-- Database: procure2pay
-- ============================================================
-- Replace the placeholder values before running in Athena:
--   {start_date}  → e.g. DATE '2026-01-01'
--   {end_date}    → e.g. DATE '2026-06-11'
--   {year_month}  → year/month filter (see section 2)
-- ============================================================


-- ============================================================
-- QUERY 1: ALL 8 KPIs IN ONE QUERY (Main Dashboard Query)
-- KPIs covered:
--   1. Total Spend
--   2. Active PO's
--   3. Total PO's
--   4. Active Vendors
--   5. Pending Invoices
--   6. Avg Invoice Processing Time
--   7. First Pass Invoices %
--   8. Autoprocessed Invoices %
-- ============================================================

WITH fact_agg AS (
    SELECT
        -- KPI 1: Total Spend (excludes CANCELLED / REJECTED)
        SUM(CASE
            WHEN UPPER(f.invoice_status) NOT IN ('CANCELLED','REJECTED')
            THEN COALESCE(f.invoice_amount_local, 0)
            ELSE 0
        END) AS total_spend,

        -- KPI 2: Active PO's (POs with at least one OPEN invoice)
        COUNT(DISTINCT CASE
            WHEN UPPER(f.invoice_status) = 'OPEN'
            THEN f.purchase_order_reference
        END) AS active_pos,

        -- KPI 3: Total PO's (all distinct POs in period)
        COUNT(DISTINCT f.purchase_order_reference) AS total_pos,

        -- KPI 5: Pending Invoices (OPEN status)
        COUNT(DISTINCT CASE
            WHEN UPPER(f.invoice_status) = 'OPEN'
            THEN f.invoice_number
        END) AS pending_inv,

        -- KPI 4: Active Vendors (vendors with invoices in period)
        COUNT(DISTINCT CASE
            WHEN v.vendor_name IS NOT NULL
            THEN v.vendor_name
        END) AS active_vendors

    FROM procure2pay.fact_all_sources_vw f
    LEFT JOIN procure2pay.dim_vendor_vw v
        ON f.vendor_id = v.vendor_id
    WHERE f.posting_date BETWEEN {start_date} AND {end_date}
    -- Optional vendor filter: AND v.vendor_name = 'Vendor Name Here'
),

-- KPI 6: Avg Invoice Processing Time
-- Source: payment_processing_cycle_time_vw
-- Filter: year/month range matching the date filter above
cycle_agg AS (
    SELECT AVG(CAST(avg_payment_cycle_time_days AS DOUBLE)) AS avg_days
    FROM procure2pay.payment_processing_cycle_time_vw
    WHERE (year > YEAR({start_date})
           OR (year = YEAR({start_date}) AND month >= MONTH({start_date})))
      AND (year < YEAR({end_date})
           OR (year = YEAR({end_date}) AND month <= MONTH({end_date})))
),

-- KPI 7: First Pass Invoices %
-- = full_paid_invoices / total_cleared_invoices * 100
-- Source: full_payment_rate_vw
fp_agg AS (
    SELECT
        SUM(CAST(full_paid_invoices     AS BIGINT)) AS full_paid,
        SUM(CAST(total_cleared_invoices AS BIGINT)) AS total_cleared
    FROM procure2pay.full_payment_rate_vw
    WHERE (year > YEAR({start_date})
           OR (year = YEAR({start_date}) AND month >= MONTH({start_date})))
      AND (year < YEAR({end_date})
           OR (year = YEAR({end_date}) AND month <= MONTH({end_date})))
),

-- KPI 8: Autoprocessed Invoices %
-- = invoices with status_notes = 'AUTO PROCESSED' / total cleared * 100
-- Source: invoice_status_history_vw
auto_agg AS (
    SELECT
        COUNT(*) AS total_cleared_inv,
        SUM(CASE
            WHEN UPPER(status_notes) = 'AUTO PROCESSED' THEN 1
            ELSE 0
        END) AS auto_proc
    FROM procure2pay.invoice_status_history_vw
    WHERE posting_date BETWEEN {start_date} AND {end_date}
      AND UPPER(status) IN ('PAID', 'CLEARED')
)

SELECT
    fa.total_spend,
    fa.active_pos,
    fa.total_pos,
    fa.pending_inv,
    fa.active_vendors,
    ca.avg_days                                              AS avg_processing_days,
    fp.full_paid                                             AS fp_full_paid,
    fp.total_cleared                                         AS fp_total_cleared,
    CASE WHEN fp.total_cleared > 0
         THEN ROUND(fp.full_paid * 100.0 / fp.total_cleared, 2)
         ELSE 0
    END                                                      AS first_pass_rate_pct,
    aa.total_cleared_inv                                     AS auto_total,
    aa.auto_proc                                             AS auto_processed,
    CASE WHEN aa.total_cleared_inv > 0
         THEN ROUND(aa.auto_proc * 100.0 / aa.total_cleared_inv, 2)
         ELSE 0
    END                                                      AS auto_rate_pct
FROM fact_agg fa
CROSS JOIN cycle_agg ca
CROSS JOIN fp_agg fp
CROSS JOIN auto_agg aa;


-- ============================================================
-- QUERY 2: Avg Processing Time FALLBACK
-- Used when payment_processing_cycle_time_vw returns NULL
-- Calculates directly from fact table using actual payment dates
-- ============================================================

SELECT
    AVG(CAST(DATE_DIFF('day', posting_date, payment_date) AS DOUBLE)) AS avg_processing_days
FROM procure2pay.fact_all_sources_vw
WHERE UPPER(invoice_status) IN ('PAID', 'CLEARED')
  AND payment_date IS NOT NULL
  AND posting_date BETWEEN {start_date} AND {end_date};


-- ============================================================
-- QUERY 3: Needs Attention — Overdue / Disputed / Due Soon
-- ============================================================

-- 3a. Overdue invoices
SELECT
    f.invoice_number    AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN {start_date} AND {end_date}
  AND f.due_date < CURRENT_DATE
  AND UPPER(f.invoice_status) = 'OVERDUE'
ORDER BY f.due_date ASC;

-- 3b. Disputed invoices
SELECT
    f.invoice_number    AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN {start_date} AND {end_date}
  AND UPPER(f.invoice_status) IN ('DISPUTE', 'DISPUTED')
ORDER BY f.due_date ASC;

-- 3c. Due in next 30 days
SELECT
    f.invoice_number    AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN {start_date} AND {end_date}
  AND f.due_date >= CURRENT_DATE
  AND f.due_date <= CURRENT_DATE + INTERVAL '30' DAY
  AND UPPER(f.invoice_status) = 'OPEN'
ORDER BY f.due_date ASC;


-- ============================================================
-- QUERY 4: Invoice Status Distribution (Donut Chart)
-- ============================================================

SELECT
    CASE
        WHEN UPPER(invoice_status) IN ('PAID','CLEARED','CLOSED','POSTED','SETTLED')
            THEN 'Paid'
        WHEN UPPER(invoice_status) IN ('OPEN','PENDING','ON HOLD','PARKED','IN PROGRESS')
            THEN 'Pending'
        WHEN UPPER(invoice_status) IN ('DISPUTE','DISPUTED','BLOCKED','CONTESTED')
            THEN 'Disputed'
        ELSE 'Other'
    END AS status,
    COUNT(*) AS cnt
FROM procure2pay.fact_all_sources_vw
WHERE posting_date BETWEEN {start_date} AND {end_date}
  AND UPPER(invoice_status) NOT IN ('CANCELLED','REJECTED')
GROUP BY 1
ORDER BY cnt DESC;


-- ============================================================
-- QUERY 5: Top 10 Vendors by Spend (Bar Chart)
-- ============================================================

SELECT
    COALESCE(v.vendor_name, 'Unknown') AS vendor_name,
    SUM(COALESCE(f.invoice_amount_local, 0)) AS total_spend
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN {start_date} AND {end_date}
  AND UPPER(f.invoice_status) NOT IN ('CANCELLED','REJECTED')
GROUP BY 1
ORDER BY total_spend DESC
LIMIT 10;


-- ============================================================
-- QUERY 6: Spend Trend Analysis (Last 6 Months Bar Chart)
-- ============================================================

SELECT
    DATE_TRUNC('month', posting_date) AS month,
    SUM(COALESCE(invoice_amount_local, 0)) AS actual_spend
FROM procure2pay.fact_all_sources_vw
WHERE posting_date >= DATE_ADD('month', -6, {end_date})
  AND UPPER(invoice_status) NOT IN ('CANCELLED', 'REJECTED')
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- QUICK REFERENCE: Views used
-- ============================================================
-- procure2pay.fact_all_sources_vw          → Main invoice/PO fact table
-- procure2pay.dim_vendor_vw                → Vendor dimension
-- procure2pay.payment_processing_cycle_time_vw → Avg cycle time by month
-- procure2pay.full_payment_rate_vw         → First pass rate by month
-- procure2pay.invoice_status_history_vw   → Invoice status history (auto-processing)
-- procure2pay.cash_flow_forecast_vw       → Cash flow forecast (Forecast page)
-- procure2pay.gr_ir_outstanding_balance_vw → GR/IR reconciliation
-- procure2pay.gr_ir_aging_vw              → GR/IR aging buckets
