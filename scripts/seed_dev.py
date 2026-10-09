"""Seed fixtures for the G1' local dev site (idempotent).

Runs inside the bench container: ``env/bin/python /seed/seed_dev.py``.
Creates what the A4a read contract (erp-enterprise-app
docs/A4A_READ_CONTRACT.md) needs:

- upstream setup-wizard default masters (item groups, territories,
  customer groups, UOMs, price lists) via install_fixtures.*
- TWO companies (A + B) so User-Permission scoping has a cross-company axis
- 2 Customers + 2 Items
- scoped service user ``ewcp-agent@ewcp.dev`` (roles: Accounts User —
  read coverage for Customer/Item/Company/Sales Invoice/PLE per FAC F4 —
  plus ``EWCP Write``, the A5b draft-PO write role installed by the app's
  fixtures; NOT Administrator)
- api_key/api_secret pair, written to $SECRETS_OUT
- User Permissions: Company -> A only (apply_to_all_doctypes),
  Customer -> A1 only; System Settings apply_strict_user_permissions = 1
  (FAC F2/F3)

One submitted Sales Invoice on Company A is attempted best-effort so the
receivables surface has a row; failure is logged, not fatal.
"""

import os
import sys
import traceback

# frappe resolves log paths as "../logs" relative to cwd — bench convention
# is to run with cwd = <bench>/sites.
os.chdir("/home/frappe/frappe-bench/sites")
sys.path.insert(0, "/home/frappe/frappe-bench/apps")

import frappe  # noqa: E402
from frappe.utils import getdate  # noqa: E402
from erpnext.setup.setup_wizard.operations import install_fixtures  # noqa: E402

SITE = os.environ.get("SITE_NAME", "ewcp-dev.localhost")
COUNTRY = "United States"
CURRENCY = "USD"
COMPANY_A = "EWCP Dev Company A"
COMPANY_B = "EWCP Dev Company B"
CUSTOMER_A = "EWCP Dev Customer A1"
CUSTOMER_B = "EWCP Dev Customer B1"
AGENT_USER = "ewcp-agent@ewcp.dev"
SECRETS_OUT = os.environ.get("SECRETS_OUT", "/secrets/ewcp-agent.env")

frappe.init(site=SITE)
frappe.connect()
frappe.set_user("Administrator")

log = print


def step(name):
    log(f"\n=== {name} ===")


step("default masters (setup-wizard fixtures)")
if frappe.db.exists("Item Group", "All Item Groups"):
    log("masters already installed — skipping")
else:
    install_fixtures.install(country=COUNTRY)

step("companies")
args = frappe._dict(
    company_name=COMPANY_A,
    company_abbr="EDA",
    currency=CURRENCY,
    country=COUNTRY,
    fy_start_date=f"{getdate(frappe.utils.nowdate()).year}-01-01",
    fy_end_date=f"{getdate(frappe.utils.nowdate()).year}-12-31",
    chart_of_accounts="Standard",
    domain="Services",
)
if not frappe.db.exists("Company", COMPANY_A):
    install_fixtures.install_company(args)
    install_fixtures.install_defaults(args)
    log(f"created {COMPANY_A} (Standard COA, FY {getdate().year})")
else:
    log(f"{COMPANY_A} exists")

if not frappe.db.exists("Company", COMPANY_B):
    frappe.get_doc(
        {
            "doctype": "Company",
            "company_name": COMPANY_B,
            "abbr": "EDB",
            "default_currency": CURRENCY,
            "country": COUNTRY,
            "create_chart_of_accounts_based_on": "Standard Template",
            "chart_of_accounts": "Standard",
            "domain": "Services",
        }
    ).insert(ignore_permissions=True)
    log(f"created {COMPANY_B} (Standard COA)")
else:
    log(f"{COMPANY_B} exists")

step("customers + items")
for name in (CUSTOMER_A, CUSTOMER_B):
    if not frappe.db.exists("Customer", name):
        frappe.get_doc(
            {
                "doctype": "Customer",
                "customer_name": name,
                "customer_type": "Company",
                "customer_group": "Commercial",  # leaf under All Customer Groups
                "territory": "Rest Of The World",  # leaf under All Territories
            }
        ).insert(ignore_permissions=True)
        log(f"created Customer {name}")

for code, item_name, grp in (
    ("EWCP-ITEM-001", "EWCP Dev Service Item", "Services"),
    ("EWCP-ITEM-002", "EWCP Dev Widget", "Products"),
):
    if not frappe.db.exists("Item", code):
        frappe.get_doc(
            {
                "doctype": "Item",
                "item_code": code,
                "item_name": item_name,
                "item_group": grp,
                "is_stock_item": 0,
                "stock_uom": "Nos",
            }
        ).insert(ignore_permissions=True)
        log(f"created Item {code}")

for pl in ("Standard Buying", "Standard Selling"):
    if not frappe.db.exists("Price List", pl):
        frappe.get_doc(
            {
                "doctype": "Price List",
                "price_list_name": pl,
                "enabled": 1,
                "buying": 1 if pl.endswith("Buying") else 0,
                "selling": 1 if pl.endswith("Selling") else 0,
                "currency": CURRENCY,
            }
        ).insert(ignore_permissions=True)
        log(f"created Price List {pl}")

step("company defaults (round-off / receivable / income / cost center)")
for co, abbr in ((COMPANY_A, "EDA"), (COMPANY_B, "EDB")):
    co_doc = frappe.get_doc("Company", co)
    defaults = {
        "round_off_account": f"Round Off - {abbr}",
        "write_off_account": f"Miscellaneous Expenses - {abbr}",
        "exchange_gain_loss_account": f"Miscellaneous Expenses - {abbr}",
        "default_receivable_account": f"Debtors - {abbr}",
        "default_payable_account": f"Creditors - {abbr}",
        "default_income_account": f"Sales - {abbr}",
        "cost_center": f"Main - {abbr}",
    }
    changed = False
    for field, val in defaults.items():
        link_dt = "Cost Center" if field == "cost_center" else "Account"
        if co_doc.get(field) != val and frappe.db.exists(link_dt, val):
            co_doc.set(field, val)
            changed = True
    if changed:
        co_doc.save(ignore_permissions=True)
        log(f"set company defaults on {co}")

step("sales invoice (best-effort, receivables fixture)")
submitted = frappe.get_all(
    "Sales Invoice", {"company": COMPANY_A, "docstatus": 1}, pluck="name"
)
if submitted and frappe.db.count("GL Entry", {"voucher_no": submitted[0]}) > 0:
    log(f"Sales Invoice {submitted[0]} already posted with GL rows")
else:
    # a failed submit can leave a half-posted SI (docstatus=1, no GL) — drop all
    # company-A SIs and rebuild cleanly; submitted rows need docstatus=2 first
    for name in frappe.get_all("Sales Invoice", {"company": COMPANY_A}, pluck="name"):
        if frappe.db.get_value("Sales Invoice", name, "docstatus") == 1:
            frappe.db.set_value("Sales Invoice", name, "docstatus", 2)
        frappe.delete_doc("Sales Invoice", name, force=True, ignore_permissions=True)
        log(f"deleted stale/partial SI {name}")
    try:
        receivable = frappe.db.get_value(
            "Account", {"company": COMPANY_A, "account_type": "Receivable", "is_group": 0}, "name"
        )
        income = frappe.db.get_value(
            "Account", {"company": COMPANY_A, "root_type": "Income", "is_group": 0}, "name", order_by="name"
        )
        si = frappe.get_doc(
            {
                "doctype": "Sales Invoice",
                "customer": CUSTOMER_A,
                "company": COMPANY_A,
                "posting_date": frappe.utils.nowdate(),
                "due_date": frappe.utils.add_days(frappe.utils.nowdate(), 30),
                "currency": CURRENCY,
                "debit_to": receivable,
                "selling_price_list": "Standard Selling",
                "price_list_currency": CURRENCY,
                "plc_conversion_rate": 1,
                "items": [
                    {
                        "item_code": "EWCP-ITEM-001",
                        "qty": 2,
                        "rate": 150.0,
                        "uom": "Nos",
                        "income_account": income,
                    }
                ],
            }
        )
        si.insert(ignore_permissions=True)
        si.submit()
        gl = frappe.db.count("GL Entry", {"voucher_no": si.name})
        ple = frappe.db.count("Payment Ledger Entry", {"voucher_no": si.name})
        log(f"created + submitted Sales Invoice {si.name} gl={gl} ple={ple}")
    except Exception:
        log("SI seed skipped — see traceback below")
        traceback.print_exc()
        if si.name:
            frappe.db.rollback()
            frappe.delete_doc("Sales Invoice", si.name, force=True, ignore_permissions=True)

step("supplier (A5b write-path fixture)")
SUPPLIER_A = "EWCP Dev Supplier A1"
if not frappe.db.exists("Supplier Group", "Services"):
    frappe.get_doc(
        {
            "doctype": "Supplier Group",
            "supplier_group_name": "Services",
            "parent_supplier_group": "All Supplier Groups",
            "is_group": 0,
        }
    ).insert(ignore_permissions=True)
    log("created Supplier Group Services")
if not frappe.db.exists("Supplier", SUPPLIER_A):
    frappe.get_doc(
        {
            "doctype": "Supplier",
            "supplier_name": SUPPLIER_A,
            "supplier_group": "Services",
            "supplier_type": "Company",
            "country": COUNTRY,
        }
    ).insert(ignore_permissions=True)
    log(f"created Supplier {SUPPLIER_A}")

step("system settings: strict user permissions")
# set_single_value bypasses doc-level mandatory fields (language/time_zone are
# unset pre-setup-wizard, so a full doc.save() raises MandatoryError)
frappe.db.set_single_value("System Settings", "apply_strict_user_permissions", 1)
if not frappe.db.get_single_value("System Settings", "language"):
    frappe.db.set_single_value("System Settings", "language", "en")
    frappe.db.set_single_value("System Settings", "time_zone", "UTC")
log("apply_strict_user_permissions=1")

step("scoped service user + api keys")
if not frappe.db.exists("User", AGENT_USER):
    user = frappe.get_doc(
        {
            "doctype": "User",
            "email": AGENT_USER,
            "first_name": "EWCP Dev Agent",
            "enabled": 1,
            "user_type": "System User",
            "send_welcome_email": 0,
            "roles": [{"role": "Accounts User"}, {"role": "EWCP Write"}],
        }
    )
    user.insert(ignore_permissions=True)
else:
    user = frappe.get_doc("User", AGENT_USER)
    user.enabled = 1
    user.user_type = "System User"
    user.set("roles", [{"role": "Accounts User"}, {"role": "EWCP Write"}])

api_key = frappe.generate_hash(length=20)
api_secret = frappe.generate_hash(length=20)
user.api_key = api_key
user.api_secret = api_secret
user.save(ignore_permissions=True)
log(f"user {AGENT_USER}: roles={[r.role for r in user.roles]}")

step("user permissions")


def ensure_up(allow, for_value):
    if frappe.db.exists("User Permission", {"user": AGENT_USER, "allow": allow, "for_value": for_value}):
        return
    frappe.get_doc(
        {
            "doctype": "User Permission",
            "user": AGENT_USER,
            "allow": allow,
            "for_value": for_value,
            "apply_to_all_doctypes": 1,
        }
    ).insert(ignore_permissions=True)
    log(f"User Permission {allow} -> {for_value}")


ensure_up("Company", COMPANY_A)
ensure_up("Customer", CUSTOMER_A)

frappe.db.commit()

os.makedirs(os.path.dirname(SECRETS_OUT), exist_ok=True)
with open(SECRETS_OUT, "w") as f:
    f.write(f"ERPNEXT_BASE_URL=http://localhost:8080\n")
    f.write(f"ERPNEXT_SITE={SITE}\n")
    f.write(f"ERPNEXT_API_USER={AGENT_USER}\n")
    f.write(f"ERPNEXT_API_KEY={api_key}\n")
    f.write(f"ERPNEXT_API_SECRET={api_secret}\n")
os.chmod(SECRETS_OUT, 0o600)

log(f"\nSEED_OK wrote {SECRETS_OUT} (api_key={api_key[:4]}…) — file is gitignored")
