"""
Retraining for the Rwanda crop price API.

    POST /retrain          - upload a CSV of new price records; uploading it starts retraining
    GET  /retrain/status   - progress and the error on the new rows before and after

prediction.py includes this router. The live model is kept in prediction.py; this module swaps in the
retrained one when it is ready, so /predict uses it without a redeploy.
"""

import copy
import io
import threading

import numpy as np
import pandas as pd
from fastapi import APIRouter, File, HTTPException, UploadFile
from sklearn.base import clone
from sklearn.linear_model import SGDRegressor
from sklearn.metrics import mean_squared_error

FEATURES_CAT = ["commodity", "market", "province", "district"]
FEATURES_NUM = ["latitude", "longitude", "year", "month"]
FEATURES = FEATURES_CAT + FEATURES_NUM
TARGET = "price"
RAW_COLUMNS = ["date", "admin1", "admin2", "market", "latitude", "longitude",
               "commodity", "unit", "priceflag", "pricetype", "price"]

router = APIRouter(tags=["retraining"])


# --------------------------------------------------------------------------------------
# Cleaning. Identical to clean() and remove_outliers() in multivariate.ipynb.
# --------------------------------------------------------------------------------------
def clean(df: pd.DataFrame) -> pd.DataFrame:
    df = df[~df["date"].astype(str).str.startswith("#")].copy()
    df = df[(df["unit"] == "KG") & (df["pricetype"] == "Retail") & (df["priceflag"] == "actual")]
    df["price"] = pd.to_numeric(df["price"], errors="coerce")
    df["latitude"] = pd.to_numeric(df["latitude"], errors="coerce")
    df["longitude"] = pd.to_numeric(df["longitude"], errors="coerce")
    date = pd.to_datetime(df["date"], errors="coerce")
    df["year"] = date.dt.year
    df["month"] = date.dt.month
    df = df.rename(columns={"admin1": "province", "admin2": "district"})
    df = df[FEATURES + [TARGET]].dropna()
    df = df[df["price"] > 0].drop_duplicates()
    df[["year", "month"]] = df[["year", "month"]].astype(int)
    return df


def remove_outliers(df: pd.DataFrame) -> pd.DataFrame:
    logp = np.log(df["price"])
    q1 = logp.groupby(df["commodity"]).transform(lambda s: s.quantile(0.25))
    q3 = logp.groupby(df["commodity"]).transform(lambda s: s.quantile(0.75))
    iqr = q3 - q1
    return df[(logp >= q1 - 3 * iqr) & (logp <= q3 + 3 * iqr)]


# Retraining state, shown by GET /retrain/status.
retrain_status: dict = {"state": "idle"}


def _retrain_job(new: pd.DataFrame) -> None:
    """Runs in a background thread so a slow refit on Render's small CPU can't time out the request."""
    import prediction as api  # holds the live model; imported here to avoid a circular import

    try:
        model, training_data = api.model, api.training_data
        y_new_log = np.log1p(new[TARGET].astype(float))
        mse_before = mean_squared_error(y_new_log, np.log1p(model.predict(new[FEATURES])))

        if isinstance(model.regressor_.named_steps["model"], SGDRegressor):
            # SGD: continue gradient descent from the current weights on the new rows only.
            updated = copy.deepcopy(model)  # train a copy; the live model keeps serving meanwhile
            pre = updated.regressor_.named_steps["pre"]
            updated.regressor_.named_steps["model"].partial_fit(pre.transform(new[FEATURES]), y_new_log)
            combined = pd.concat([training_data, new], ignore_index=True)
            how = "partial_fit on new rows (SGDRegressor)"
        else:
            # Tree models can't learn incrementally: refit a fresh copy (same hyperparameters)
            # on the original data plus the new rows.
            combined = remove_outliers(pd.concat([training_data, new], ignore_index=True).drop_duplicates())
            updated = clone(model).fit(combined[FEATURES], combined[TARGET])
            how = "refit on original + new rows"

        mse_after = mean_squared_error(y_new_log, np.log1p(updated.predict(new[FEATURES])))
        with api._lock:  # swap in the new model; /predict uses it from now on
            api.model, api.training_data = updated, combined
        # The new model lives in memory only. It isn't written over best_model.pkl, so the file in the
        # repository stays the one trained in the notebook (Render would wipe a saved copy on restart anyway).

        retrain_status.update({
            "state": "done",
            "finished_at": pd.Timestamp.now(tz="UTC").isoformat(timespec="seconds"),
            "message": "Model retrained and now in use by /predict.",
            "model": api.model_name(updated),
            "method": how,
            "total_training_rows": int(len(combined)),
            "mse_on_new_rows_before": round(float(mse_before), 4),
            "mse_on_new_rows_after": round(float(mse_after), 4),
        })
    except Exception as exc:  # report the failure instead of losing it in a thread
        retrain_status.update({"state": "failed", "error": str(exc)})


@router.post("/retrain", status_code=202)
async def retrain(file: UploadFile = File(..., description="CSV of new price records (WFP format)")):
    """
    Upload a CSV of new price records. **Uploading it triggers retraining**: no other step is needed.
    The file is checked and cleaned straight away, then the model retrains in the background.
    Check progress with GET /retrain/status. When it says "done", /predict uses the new model.

    Accepted formats:
      - the raw WFP/HDX export (columns: date, admin1, admin2, market, latitude, longitude,
        commodity, unit, priceflag, pricetype, price, ...); it's cleaned exactly as in the notebook
      - or the cleaned format: commodity, market, province, district, latitude, longitude, year, month, price

    If the model is SGDRegressor, it keeps training on the new rows with partial_fit.
    Otherwise (tree models) it's refit on the original data plus the new rows.
    """
    if retrain_status.get("state") == "running":
        raise HTTPException(status_code=409, detail="A retraining job is already running. Check /retrain/status.")
    if not (file.filename or "").lower().endswith(".csv"):
        raise HTTPException(status_code=400, detail="Please upload a .csv file.")
    try:
        new = pd.read_csv(io.BytesIO(await file.read()), low_memory=False)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not read CSV: {exc}")

    if set(RAW_COLUMNS).issubset(new.columns):
        new = clean(new)
    elif set(FEATURES + [TARGET]).issubset(new.columns):
        new = new[FEATURES + [TARGET]].dropna()
        new = new[pd.to_numeric(new[TARGET], errors="coerce") > 0]
    else:
        missing = sorted(set(FEATURES + [TARGET]) - set(new.columns))
        raise HTTPException(status_code=422, detail=f"CSV is missing columns: {missing}. "
                            f"Use the WFP format or: {FEATURES + [TARGET]}")
    if new.empty:
        raise HTTPException(status_code=422, detail="No usable rows (need retail, actual, per-KG prices).")

    started = pd.Timestamp.now(tz="UTC").isoformat(timespec="seconds")
    retrain_status.clear()
    retrain_status.update({"state": "running", "file": file.filename, "new_rows_used": int(len(new)),
                           "started_at": started})
    threading.Thread(target=_retrain_job, args=(new,), daemon=True).start()
    return {"message": "Upload accepted. Retraining started; check GET /retrain/status.",
            "new_rows_used": int(len(new)), "started_at": started}


@router.get("/retrain/status")
def retrain_status_route():
    """State of the latest retraining job: idle, running, done (with before/after MSE) or failed."""
    return retrain_status
