# Rwanda Crop Price Predictor

## Mission and problem
My mission is to use software engineering and machine learning to solve agricultural challenges in East Africa, so farmers can raise productivity, reach markets and become financially sustainable.
Many Rwandan farmers sell without knowing what their crop is worth in nearby markets, so buyers set the price.
This project predicts the retail price (RWF per kg) of a crop in a given market and month, so a farmer can choose where and when to sell.

## Dataset
**WFP Food Prices for Rwanda**, published by the World Food Programme on the Humanitarian Data Exchange (HDX): <https://data.humdata.org/dataset/wfp-food-prices-for-rwanda>.
It holds about 158,000 monthly market price records (2000–2026) for 65 commodities in 100+ Rwandan markets, with 16 columns mixing numeric and categorical data (date, province, district, market, latitude, longitude, category, commodity, unit, price type, currency, price and more). Data was downloaded in November 2026, and a copy is stored in `summative/linear_regression/data/`. The model uses the retail, per-kg slice (about 129,000 rows).

## API (Swagger UI)
Public Swagger UI: **https://rwanda-crop-price-api-ryiy.onrender.com/docs**

> The free Render service sleeps after 15 minutes without traffic. The first request can take up to a minute while it wakes up.

| Route | Method | Purpose |
|---|---|---|
| `/predict` | POST | Takes the 8 inputs and returns the predicted price in RWF/kg |
| `/retrain` | POST | Upload a CSV of new price records; uploading starts retraining automatically |
| `/retrain/status` | GET | Shows retraining progress and the error on the new rows before and after |
| `/options` | GET | Lists the accepted commodity, market, province and district names |
| `/docs` | GET | Swagger UI |

To try retraining, upload [`summative/API/sample_new_data.csv`](summative/API/sample_new_data.csv) (June–August 2026 prices that were held back from training) to `/retrain`, then check `/retrain/status`.

## Video demo
YouTube: <https://youtu.be/WzHS5MS0KCw>

## Run the mobile app
1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) and Android Studio, then check the setup:
   ```bash
   flutter doctor
   ```
2. Start an Android emulator (or plug in an Android phone with USB debugging on):
   ```bash
   flutter emulators --launch Pixel_7
   ```
3. Go to the app folder and install packages:
   ```bash
   cd linear_regression_model/summative/FlutterApp
   flutter pub get
   ```
4. Run the app:
   ```bash
   flutter run
   ```
5. Fill in the 8 fields (example: `Maize`, `Nyabugogo`, `Kigali City`, `Nyarugenge`, `-1.95`, `30.06`, `2025`, `3`) and tap **Predict**. The app calls the public API above. If the API was asleep, the first prediction can take up to a minute.

## Run the notebook and API locally (optional)
Requires [uv](https://docs.astral.sh/uv/).
```bash
cd linear_regression_model/summative
uv sync --group notebook
uv run jupyter notebook linear_regression/multivariate.ipynb
```
```bash
cd linear_regression_model/summative/API
uv run uvicorn prediction:app --reload
```
Then open <http://127.0.0.1:8000/docs>.

## Deploy the API on Render
1. Push this repository to GitHub. (Quickest: in Render choose **New → Blueprint** and pick the repo; `render.yaml` holds the settings below.)
2. On [Render](https://render.com), choose **New → Web Service** and connect the repository.
3. Use these settings:
   - **Root Directory:** `summative/API`
   - **Runtime:** Python
   - **Build Command:** `pip install -r requirements.txt`
   - **Start Command:** `uvicorn prediction:app --host 0.0.0.0 --port $PORT`
   - **Instance type:** Free
   - **Environment variable:** `PYTHON_VERSION` = `3.12.13`
4. After the first deploy, open `https://<your-service>.onrender.com/docs`. If the service name differs from `rwanda-crop-price-api`, update the URL in this README, in `ALLOWED_ORIGINS` in `prediction.py`, and in `apiBaseUrl` in `FlutterApp/lib/main.dart`.
