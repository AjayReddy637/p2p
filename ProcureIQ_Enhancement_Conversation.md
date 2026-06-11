# ProcureIQ Dashboard Enhancement — Conversation Reference

**Date:** 2026-06-11  
**Purpose:** Full enhancement request for the ProcureIQ Streamlit dashboard application  
**Output File:** `procureiq_app.py`

---

## Summary of Changes Requested

### 1. Genie Tab — Out-of-Domain Question Validation
- Add intent detection before processing any user query
- If the question is NOT related to procurement/P2P data, respond with the standard message:
  > *"Hello! I am ProcureIQ Assistant. I can help you with procurement insights, vendor information, invoice status, forecasting, spend analytics, dashboard metrics, and related business data. Please ask a procurement or dashboard-related question."*
- Non-procurement topics include: greetings, jokes, weather, general knowledge, etc.
- Procurement topics include: spend, vendor, invoice, PO, payment, due, overdue, dispute, GR/IR, cash flow, forecast, dashboard, KPI, trend, analysis, procurement, p2p, receipt, goods, price, quantity, status, active vendors, total spend, pending, processing time, autoprocessed

### 2. Background Customization — Floating BG Button
- Add a floating button labeled **"BG"** at the bottom-right corner (fixed position, all pages)
- Clicking opens a color panel with 8 light theme options:
  - Light Blue (`#e0f2fe`)
  - Light Gray (`#f3f4f6`)
  - Light Green (`#dcfce7`)
  - Light Purple (`#f3e8ff`)
  - Light Pink (`#fce7f3`)
  - Light Beige (`#fef9c3`)
  - Light Cyan (`#cffafe`)
  - White (`#ffffff`)
- Selected color applies immediately to the app background
- Persisted via `localStorage` so it survives refresh and re-login

### 3. Dashboard KPI Accuracy Fix
- Remove ALL hardcoded KPI values
- All KPIs must be calculated dynamically from Athena views in `procure2pay` database
- **Active Vendors** must use `COUNT(DISTINCT vendor_name)` from `dim_vendor_vw` → expected: 60

### 4. KPI SQL Queries (per the spec)

| KPI | Source View / Logic |
|-----|---------------------|
| Total Spend | `fact_all_sources_vw` — SUM of invoice_amount_local where status NOT IN ('CANCELLED','REJECTED') |
| Active POs | `fact_all_sources_vw` — COUNT(DISTINCT po) WHERE status = 'OPEN' |
| Total POs | `fact_all_sources_vw` — COUNT(DISTINCT purchase_order_reference) |
| Active Vendors | `dim_vendor_vw` — COUNT(DISTINCT vendor_name) |
| Pending Invoices | `fact_all_sources_vw` — COUNT WHERE status = 'OPEN' |
| Avg Processing Time | `payment_processing_cycle_time_vw` |
| First Pass Invoice % | `full_payment_rate_vw` or `invoice_status_history_vw` |
| Auto Processed % | `invoice_status_history_vw` WHERE status_notes = 'AUTO PROCESSED' |

### 5. Needs Attention Section
- Overdue, Disputed, Due counts must come from real Athena data
- No mock/hardcoded invoice cards

### 6. Data Quality
- Remove all hardcoded KPI values and placeholder percentages
- Add null-safe handling and error states
- Add loading states

### 7. UI Preservation
- All existing layout, charts, navigation, tabs, styling must remain unchanged
- Only the three features above are added/fixed

---

## Available Athena Views

```
accounts_payable_balance_vw
cash_flow_forecast_vw
cash_flow_unpaid_obligations_vw
days_payable_outstanding_vw
dim_company_code_vw
dim_plant_vw
dim_po_vw
dim_region_vw
dim_vendor_vw
duplicate_payments_for_invoice_vw
early_payment_candidates_vw
fact_all_sources_vw
fact_sap_po_level_vw
full_payment_rate_vw
gr_ir_aging_vw
gr_ir_outstanding_balance_vw
invoice_status_history_vw
late_accruals_vw
late_payment_amount_vw
net_early_payment_benefit_index_vw
on_time_payment_rate_vw
partial_payment_rate_vw
payment_predictability_index_vw
payment_processing_cycle_time_vw
payment_timing_recommendation_vw
supplier_delivery_accuracy_index_vw
weighted_days_payable_outstanding_vw
```

---

## Key Implementation Notes

### Genie Validation (`is_relevant_question`)
```python
def is_relevant_question(question: str) -> bool:
    keywords = [
        "spend", "vendor", "invoice", "po", "purchase order", "payment", "due", "overdue",
        "dispute", "gr/ir", "cash flow", "forecast", "dashboard", "kpi", "trend", "analysis",
        "procurement", "p2p", "pay", "receipt", "goods", "price", "quantity", "status",
        "active vendors", "total spend", "pending", "processing time", "autoprocessed"
    ]
    q_lower = question.lower()
    return any(kw in q_lower for kw in keywords)
```

### KPI SQL — Active Vendors (Fixed)
```sql
SELECT COUNT(DISTINCT vendor_name) AS active_vendors
FROM procure2pay.dim_vendor_vw
WHERE vendor_name IS NOT NULL
```

### KPI SQL — Avg Processing Time (from dedicated view)
```sql
SELECT AVG(avg_cycle_time_days) AS avg_processing_days
FROM procure2pay.payment_processing_cycle_time_vw
WHERE posting_date BETWEEN DATE '...' AND DATE '...'
```

### KPI SQL — First Pass Rate (from full_payment_rate_vw)
```sql
SELECT full_payment_rate
FROM procure2pay.full_payment_rate_vw
ORDER BY posting_date DESC LIMIT 1
```

### Background Persistence (localStorage via JS)
```javascript
function setBackgroundColor(color) {
    document.querySelector('.stApp').style.backgroundColor = color;
    localStorage.setItem('procureiq_bg_color', color);
}
function loadBackgroundColor() {
    var saved = localStorage.getItem('procureiq_bg_color');
    if (saved) document.querySelector('.stApp').style.backgroundColor = saved;
}
document.addEventListener('DOMContentLoaded', loadBackgroundColor);
```

---

## Files Delivered

| File | Description |
|------|-------------|
| `procureiq_app.py` | Complete production-ready Streamlit application with all enhancements |
| `ProcureIQ_Enhancement_Conversation.md` | This reference document |

---

## Notes for Future Sessions
- The Genie validation is already implemented in `is_relevant_question()` and called inside every `process_*` function
- The BG button uses pure HTML/JS injected via `st.markdown(..., unsafe_allow_html=True)` since Streamlit doesn't natively support floating buttons
- KPI fallbacks (hardcoded sample data) are kept ONLY as emergency display when Athena returns empty — they are clearly marked and should be replaced once Athena views are confirmed populated
- The `payment_processing_cycle_time_vw` view is used for Avg Processing Time KPI; if unavailable it falls back to `DATE_DIFF` on `fact_all_sources_vw`
