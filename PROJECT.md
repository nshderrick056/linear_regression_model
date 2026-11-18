# Rwanda Crop Price Predictor: project overview

This document describes the whole project: the problem, the data, the model, the API, the mobile app and how they fit together. The [README](README.md) has the short version and the run steps.

## 1. Problem and mission
My mission is to use software engineering and machine learning to solve agricultural challenges in East Africa, so farmers can raise productivity, reach markets and become financially sustainable.

Many Rwandan farmers sell at the farm gate without knowing what their crop is worth in nearby markets, so the buyer sets the price. This project predicts the **retail price (RWF per kg)** of a crop in a given Rwandan market and month. A farmer or cooperative can compare markets and months, decide where and when to sell, and negotiate with a fair reference price.

## 2. How the pieces fit

```
WFP price data (HDX CSV)
        │
        ▼
multivariate.ipynb ── clean, explore, train 4 models, pick the best
        │
        ▼ best_model.pkl (+ training_data.csv)
        │
FastAPI on Render (prediction.py)
   ├── POST /predict        ◄── Flutter app (phone) and Swagger UI
   ├── POST /retrain        ◄── CSV upload of new prices
   ├── GET  /retrain/status
   └── GET  /options        ◄── Flutter app drop-down lists
```

| Part | Location | Live link |
|---|---|---|
| Notebook | `summative/linear_regression/multivariate.ipynb` | – |
| API | `summative/API/prediction.py` | <https://rwanda-crop-price-api-ryiy.onrender.com/docs> |
| Mobile app | `summative/FlutterApp/` | Android APK built with `flutter build apk` |
| Render config | `render.yaml` | Render Blueprint, Frankfurt region, free plan |

## 3. Data
- **Source:** [WFP Food Prices for Rwanda](https://data.humdata.org/dataset/wfp-food-prices-for-rwanda) on the Humanitarian Data Exchange, downloaded November 2026. A copy is in `summative/linear_regression/data/`.
- **Size:** about 158,000 monthly price records (2000–2026), 65 commodities, 100+ markets, 16 mixed numeric and categorical columns.
- **Slice used:** retail, actual, per-kg prices, which are comparable with each other. After cleaning and removing extreme outliers per commodity, 128,814 rows remain.
- **Held back:** June–August 2026 rows are saved as `summative/API/sample_new_data.csv` and act as "new data" for testing `/retrain`.

**Features (8):** `commodity`, `market`, `province`, `district` (categorical) and `latitude`, `longitude`, `year`, `month` (numeric). **Target:** `price` in RWF/kg, modelled as `log(1 + price)` because raw prices are strongly skewed (skew 2.7, versus 0.25 after the log).

**Dropped columns:** `date` (split into year and month), `market_id` and `commodity_id` (duplicate names), `unit`, `pricetype`, `priceflag` and `currency` (constant after filtering), `category` (implied by commodity) and `usdprice` (the target in another currency, which would leak the answer).

## 4. Modelling
All preprocessing lives inside one scikit-learn pipeline that is fit on the training set only:
- **Categorical columns:** one-hot encoding for the linear models, ordinal codes for the tree models. Ordinal codes let one tree split separate many markets or crops at once, which made the forest about 4× more accurate and 35× faster to train.
- **Numeric columns:** `StandardScaler`.
- **Target:** `TransformedTargetRegressor` with `log1p` / `expm1`, so `predict()` returns RWF/kg directly.
- **Split:** 80% train and 20% test. A further 20% of the training rows is a validation set used only to tune SGD.

**Results (test set, MSE on log price):**

| Model | Train MSE | Test MSE | Test RMSE (RWF/kg) |
|---|---|---|---|
| **RandomForestRegressor** (30 trees, min 5 rows per leaf) | 0.0144 | **0.0229** | **105** |
| DecisionTreeRegressor | 0.0091 | 0.0267 | 111 |
| LinearRegression | 0.0829 | 0.0841 | 194 |
| SGDRegressor (eta0 0.001, alpha 1e-6, 38 epochs) | 0.0831 | 0.0843 | 194 |

- **Linear models underfit.** Price depends on combinations of crop, place and time, which a sum of separate effects can't capture.
- **The single tree overfits.** Its train error is a third of its test error.
- **The random forest wins.** Averaging 30 trees keeps their flexibility and cancels much of the noise. Its test MSE of 0.0229 means a typical error of about 15%.
- **Feature importance** (random forest): commodity 0.75, year 0.17, location features together about 0.07, month 0.02.
- **Forest size** was limited so retraining fits on Render's free plan. 50 trees with leaves of at least 3 rows scored 0.0205 but took 68 s, used 126 MB and made a 39 MB file. 30 trees with leaves of at least 5 rows score 0.0229 in about 21 s, using 44 MB and a 14 MB file.

## 5. API (`summative/API/prediction.py`)
- **Framework:** FastAPI with Uvicorn, deployed on Render with root directory `summative/API`.
- **`POST /predict`:**
  - Uses a Pydantic `PriceRequest` in strict mode, so wrong types such as `"2025"` instead of `2025` are rejected.
  - Enforces ranges: latitude −2.9 to −1.0, longitude 28.8 to 31.0, year 2000–2035, month 1–12.
  - Text fields must match a name the model knows, matched case-insensitively. Unknown names get "Did you mean …" suggestions.
- **`POST /retrain`:**
  - Accepts a CSV of new prices, either the raw WFP format or the cleaned format. It is cleaned exactly like the notebook data.
  - Training runs in a background thread and returns `202` straight away. A second upload while one is running gets `409`.
  - The forest is refit on the original rows plus the new rows. If the best model were SGD, it would continue training with `partial_fit` instead.
  - The new model replaces the old one in memory, so `/predict` uses it immediately. It is not written to disk, so a restart returns to the notebook's model.
- **`GET /retrain/status`:** shows progress and the error on the new rows before and after retraining. In the live test with `sample_new_data.csv` (413 usable rows), it fell from 0.0409 to 0.0349.
- **`GET /options`:** lists the accepted commodity, market, province and district names.
- **CORS:**
  - Only the live Render site and the local Flutter web debug server (port 5000) are allowed, with no wildcard.
  - Only GET and POST, and only the `Content-Type` and `Accept` headers.
  - Credentials are off, because the API uses no cookies or logins.
  - Extra origins can be added with the `ALLOWED_ORIGINS` environment variable.

## 6. Mobile app (`summative/FlutterApp/lib/main.dart`)
- **Layout:** one page with 8 labelled text fields, one per model input, a **Predict** button and a result area.
- **Drop-down lists:**
  - Commodity, market, province and district show lists loaded from `GET /options`. Typing filters the list.
  - Month offers 1–12.
  - The fields stay text fields, so they still accept typed values if the list can't load.
- **Checks before sending:** the app catches missing values and non-numbers before calling the API. Range and name errors come back from the API as `422` and are shown as readable lines such as "Month: Input should be less than or equal to 12".
- **API address:** `String.fromEnvironment('API_URL')`, defaulting to the Render URL. A 90-second timeout covers a sleeping free-tier server.

## 7. Limitations and next steps
- **Missing price drivers:** the model doesn't see rainfall, harvest timing, fuel prices or the exchange rate. Adding them is the most likely way to lower the error.
- **Uneven coverage over time:** most records are from 2011–2015, so recent years are predicted less precisely.
- **Retraining doesn't persist:** a retrained model is lost on restart. Storing models in object storage would fix that.
- **Market details aren't linked:** picking a market could fill in its province, district and coordinates automatically.

## 8. Tools
Python 3.12, uv (`pyproject.toml`, `uv.lock`), pandas, scikit-learn 1.7.2, matplotlib and seaborn, FastAPI, Pydantic, Uvicorn, Render, Flutter and the `http` package.
