-- ============================================================
-- ProcureIQ Dashboard — Athena KPI Queries
-- Filter: YTD (Year-To-Date)  2026-01-01 → 2026-06-11
-- Database: procure2pay
-- Run these directly in Athena Query Editor
-- ============================================================


-- ============================================================
-- QUERY 1: ALL 8 KPIs IN ONE QUERY
-- KPI 1  → Total Spend
-- KPI 2  → Active PO's
-- KPI 3  → Total PO's
-- KPI 4  → Active Vendors
-- KPI 5  → Pending Invoices
-- KPI 6  → Avg Invoice Processing Time
-- KPI 7  → First Pass Invoices %
-- KPI 8  → Autoprocessed Invoices %
-- ============================================================

WITH fact_agg AS (
    SELECT
        SUM(CASE
                WHEN UPPER(f.invoice_status) NOT IN ('CANCELLED','REJECTED')
                THEN COALESCE(f.invoice_amount_local, 0)
                ELSE 0
            END)                                                             AS total_spend,
        COUNT(DISTINCT CASE
                WHEN UPPER(f.invoice_status) = 'OPEN'
                THEN f.purchase_order_reference END)                        AS active_pos,
        COUNT(DISTINCT f.purchase_order_reference)                          AS total_pos,
        COUNT(DISTINCT CASE
                WHEN UPPER(f.invoice_status) = 'OPEN'
                THEN f.invoice_number END)                                  AS pending_inv,
        COUNT(DISTINCT CASE
                WHEN v.vendor_name IS NOT NULL
                THEN v.vendor_name END)                                     AS active_vendors
    FROM procure2pay.fact_all_sources_vw f
    LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
    WHERE f.posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
),

cycle_agg AS (
    SELECT AVG(CAST(avg_payment_cycle_time_days AS DOUBLE)) AS avg_days
    FROM procure2pay.payment_processing_cycle_time_vw
    WHERE year = 2026
      AND month BETWEEN 1 AND 6
),

fp_agg AS (
    SELECT
        SUM(CAST(full_paid_invoices     AS BIGINT)) AS full_paid,
        SUM(CAST(total_cleared_invoices AS BIGINT)) AS total_cleared
    FROM procure2pay.full_payment_rate_vw
    WHERE year = 2026
      AND month BETWEEN 1 AND 6
),

auto_agg AS (
    SELECT
        COUNT(*) AS total_cleared_inv,
        SUM(CASE WHEN UPPER(status_notes) = 'AUTO PROCESSED' THEN 1 ELSE 0 END) AS auto_proc
    FROM procure2pay.invoice_status_history_vw
    WHERE posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
      AND UPPER(status) IN ('PAID','CLEARED')
)

SELECT
    fa.total_spend,
    fa.active_pos,
    fa.total_pos,
    fa.pending_inv,
    fa.active_vendors,
    ca.avg_days                                                             AS avg_processing_days,
    fp.full_paid                                                            AS fp_full_paid,
    fp.total_cleared                                                        AS fp_total_cleared,
    CASE WHEN fp.total_cleared > 0
         THEN ROUND(fp.full_paid * 100.0 / fp.total_cleared, 2)
         ELSE 0
    END                                                                     AS first_pass_rate_pct,
    aa.total_cleared_inv                                                    AS auto_total,
    aa.auto_proc                                                            AS auto_processed,
    CASE WHEN aa.total_cleared_inv > 0
         THEN ROUND(aa.auto_proc * 100.0 / aa.total_cleared_inv, 2)
         ELSE 0
    END                                                                     AS auto_rate_pct
FROM fact_agg fa
CROSS JOIN cycle_agg ca
CROSS JOIN fp_agg    fp
CROSS JOIN auto_agg  aa;


-- ============================================================
-- QUERY 2: Avg Processing Time FALLBACK
-- Use if payment_processing_cycle_time_vw returns NULL
-- ============================================================

SELECT
    AVG(CAST(DATE_DIFF('day', posting_date, payment_date) AS DOUBLE)) AS avg_processing_days
FROM procure2pay.fact_all_sources_vw
WHERE UPPER(invoice_status) IN ('PAID','CLEARED')
  AND payment_date IS NOT NULL
  AND posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11';


-- ============================================================
-- QUERY 3a: Needs Attention — Overdue
-- ============================================================

SELECT
    f.invoice_number       AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
  AND f.due_date < CURRENT_DATE
  AND UPPER(f.invoice_status) = 'OVERDUE'
ORDER BY f.due_date ASC;


-- ============================================================
-- QUERY 3b: Needs Attention — Disputed
-- ============================================================

SELECT
    f.invoice_number       AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
  AND UPPER(f.invoice_status) IN ('DISPUTE','DISPUTED')
ORDER BY f.due_date ASC;


-- ============================================================
-- QUERY 3c: Needs Attention — Due in next 30 days
-- ============================================================

SELECT
    f.invoice_number       AS ref_no,
    f.invoice_amount_local AS amount,
    v.vendor_name,
    f.due_date,
    f.aging_days
FROM procure2pay.fact_all_sources_vw f
LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
WHERE f.posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
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
    END                AS status,
    COUNT(*)           AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM procure2pay.fact_all_sources_vw
WHERE posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
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
WHERE f.posting_date BETWEEN DATE '2026-01-01' AND DATE '2026-06-11'
  AND UPPER(f.invoice_status) NOT IN ('CANCELLED','REJECTED')
GROUP BY 1
ORDER BY total_spend DESC
LIMIT 10;


-- ============================================================
-- QUERY 6: Spend Trend Analysis — Last 6 Months
-- ============================================================

SELECT
    DATE_TRUNC('month', posting_date)        AS month,
    SUM(COALESCE(invoice_amount_local, 0))   AS actual_spend
FROM procure2pay.fact_all_sources_vw
WHERE posting_date >= DATE_ADD('month', -6, DATE '2026-06-11')
  AND UPPER(invoice_status) NOT IN ('CANCELLED','REJECTED')
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- QUERY 7: PRIOR PERIOD (for delta arrows — Jan 2025 → Jun 2025)
-- Run same as Query 1 but with prior year same period
-- ============================================================

WITH fact_agg AS (
    SELECT
        SUM(CASE
                WHEN UPPER(f.invoice_status) NOT IN ('CANCELLED','REJECTED')
                THEN COALESCE(f.invoice_amount_local, 0) ELSE 0
            END)                                                            AS total_spend,
        COUNT(DISTINCT CASE WHEN UPPER(f.invoice_status)='OPEN'
                THEN f.purchase_order_reference END)                        AS active_pos,
        COUNT(DISTINCT f.purchase_order_reference)                          AS total_pos,
        COUNT(DISTINCT CASE WHEN UPPER(f.invoice_status)='OPEN'
                THEN f.invoice_number END)                                  AS pending_inv,
        COUNT(DISTINCT CASE WHEN v.vendor_name IS NOT NULL
                THEN v.vendor_name END)                                     AS active_vendors
    FROM procure2pay.fact_all_sources_vw f
    LEFT JOIN procure2pay.dim_vendor_vw v ON f.vendor_id = v.vendor_id
    WHERE f.posting_date BETWEEN DATE '2025-01-01' AND DATE '2025-06-11'
),
cycle_agg AS (
    SELECT AVG(CAST(avg_payment_cycle_time_days AS DOUBLE)) AS avg_days
    FROM procure2pay.payment_processing_cycle_time_vw
    WHERE year = 2025 AND month BETWEEN 1 AND 6
),
fp_agg AS (
    SELECT
        SUM(CAST(full_paid_invoices     AS BIGINT)) AS full_paid,
        SUM(CAST(total_cleared_invoices AS BIGINT)) AS total_cleared
    FROM procure2pay.full_payment_rate_vw
    WHERE year = 2025 AND month BETWEEN 1 AND 6
),
auto_agg AS (
    SELECT
        COUNT(*) AS total_cleared_inv,
        SUM(CASE WHEN UPPER(status_notes)='AUTO PROCESSED' THEN 1 ELSE 0 END) AS auto_proc
    FROM procure2pay.invoice_status_history_vw
    WHERE posting_date BETWEEN DATE '2025-01-01' AND DATE '2025-06-11'
      AND UPPER(status) IN ('PAID','CLEARED')
)
SELECT
    fa.total_spend,
    fa.active_pos,
    fa.total_pos,
    fa.pending_inv,
    fa.active_vendors,
    ca.avg_days                                                             AS avg_processing_days,
    CASE WHEN fp.total_cleared > 0
         THEN ROUND(fp.full_paid * 100.0 / fp.total_cleared, 2) ELSE 0
    END                                                                     AS first_pass_rate_pct,
    CASE WHEN aa.total_cleared_inv > 0
         THEN ROUND(aa.auto_proc * 100.0 / aa.total_cleared_inv, 2) ELSE 0
    END                                                                     AS auto_rate_pct
FROM fact_agg fa
CROSS JOIN cycle_agg ca
CROSS JOIN fp_agg    fp
CROSS JOIN auto_agg  aa;


-- ============================================================
-- VIEWS REFERENCE
-- ============================================================
-- fact_all_sources_vw              Main invoice/PO fact table
--   Columns used: invoice_number, invoice_status, invoice_amount_local,
--                 purchase_order_reference, posting_date, due_date,
--                 aging_days, payment_date, vendor_id
--
-- dim_vendor_vw                    Vendor dimension
--   Columns used: vendor_id, vendor_name
--
-- payment_processing_cycle_time_vw Avg processing time by year/month
--   Columns used: year, month, avg_payment_cycle_time_days
--
-- full_payment_rate_vw             First-pass payment rate by year/month
--   Columns used: year, month, full_paid_invoices, total_cleared_invoices
--
-- invoice_status_history_vw        Invoice status change history
--   Columns used: posting_date, status, status_notes
-- ============================================================
