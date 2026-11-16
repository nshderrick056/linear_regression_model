import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Public API on Render. /predict is appended below.
/// For local testing against your own machine, run:
///   flutter run --dart-define=API_URL=http://10.0.2.2:8000
/// (10.0.2.2 is how the Android emulator reaches the computer's localhost.)
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://rwanda-crop-price-api-ryiy.onrender.com',
);

void main() => runApp(const CropPriceApp());

class CropPriceApp extends StatelessWidget {
  const CropPriceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crop Price Predictor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const PredictionPage(),
    );
  }
}

/// Describes one input: the JSON key the API expects, its label, a hint, and its type.
class InputSpec {
  final String key;
  final String label;
  final String hint;
  final FieldType type;
  const InputSpec(this.key, this.label, this.hint, this.type);
}

enum FieldType { text, decimal, integer }

/// One text field per model input, in the same order as the API's PriceRequest.
const List<InputSpec> inputs = [
  InputSpec('commodity', 'Commodity', 'e.g. Maize', FieldType.text),
  InputSpec('market', 'Market', 'e.g. Nyabugogo', FieldType.text),
  InputSpec('province', 'Province', 'e.g. Kigali City', FieldType.text),
  InputSpec('district', 'District', 'e.g. Nyarugenge', FieldType.text),
  InputSpec('latitude', 'Latitude', '-2.9 to -1.0, e.g. -1.95', FieldType.decimal),
  InputSpec('longitude', 'Longitude', '28.8 to 31.0, e.g. 30.06', FieldType.decimal),
  InputSpec('year', 'Year', '2000 to 2035, e.g. 2025', FieldType.integer),
  InputSpec('month', 'Month', '1 to 12, e.g. 3', FieldType.integer),
];

class PredictionPage extends StatefulWidget {
  const PredictionPage({super.key});

  @override
  State<PredictionPage> createState() => _PredictionPageState();
}

class _PredictionPageState extends State<PredictionPage> {
  final Map<String, TextEditingController> _controllers = {
    for (final spec in inputs) spec.key: TextEditingController(),
  };

  bool _loading = false;
  String? _result; // predicted price text
  String? _error; // readable error text

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Checks for missing values and wrong types before calling the API.
  /// Range checks are done by the API (Pydantic), and its message is shown the same way.
  Map<String, dynamic>? _buildBody(List<String> problems) {
    final body = <String, dynamic>{};
    for (final spec in inputs) {
      final raw = _controllers[spec.key]!.text.trim();
      if (raw.isEmpty) {
        problems.add('${spec.label} is missing.');
        continue;
      }
      switch (spec.type) {
        case FieldType.text:
          body[spec.key] = raw;
        case FieldType.decimal:
          final v = double.tryParse(raw);
          v == null ? problems.add('${spec.label} must be a number (got "$raw").') : body[spec.key] = v;
        case FieldType.integer:
          final v = int.tryParse(raw);
          v == null ? problems.add('${spec.label} must be a whole number (got "$raw").') : body[spec.key] = v;
      }
    }
    return problems.isEmpty ? body : null;
  }

  /// Sends the inputs to POST /predict and shows the price or a readable error.
  Future<void> _predict() async {
    FocusScope.of(context).unfocus();
    final problems = <String>[];
    final body = _buildBody(problems);
    if (body == null) {
      setState(() {
        _result = null;
        _error = problems.join('\n');
      });
      return;
    }

    setState(() {
      _loading = true;
      _result = null;
      _error = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/predict'),
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 90)); // a sleeping Render service can take ~1 min

      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        final price = (data['predicted_price_rwf_per_kg'] as num).toDouble();
        setState(() => _result = '${price.toStringAsFixed(0)} RWF per kg');
      } else if (response.statusCode == 422) {
        setState(() => _error = _formatValidationErrors(data['detail']));
      } else {
        setState(() => _error = 'Server error ${response.statusCode}: ${data['detail'] ?? response.body}');
      }
    } on TimeoutException {
      setState(() => _error = 'The server took too long to respond. It may be waking up; try again.');
    } catch (e) {
      setState(() => _error = 'Could not reach the server. Check your internet connection.\n($e)');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Turns FastAPI/Pydantic 422 details into lines like "Year: Input should be less than or equal to 2035".
  String _formatValidationErrors(dynamic detail) {
    if (detail is! List) return detail.toString();
    final labels = {for (final s in inputs) s.key: s.label};
    return detail.map((e) {
      final loc = (e['loc'] as List).last.toString();
      final msg = (e['msg'] as String).replaceFirst('Value error, ', '');
      return '${labels[loc] ?? loc}: $msg';
    }).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop Price Predictor'),
        backgroundColor: scheme.primaryContainer,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Predict the retail price of a crop in a Rwandan market.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            for (final spec in inputs) ...[
              TextField(
                controller: _controllers[spec.key],
                keyboardType: spec.type == FieldType.text
                    ? TextInputType.text
                    : TextInputType.numberWithOptions(decimal: spec.type == FieldType.decimal, signed: true),
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: spec.label,
                  hintText: spec.hint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 4),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _loading ? null : _predict,
                child: _loading
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Text('Predict', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 20),
            _ResultArea(result: _result, error: _error),
          ],
        ),
      ),
    );
  }
}

/// The display area: shows the predicted price, or the error message in the same place.
class _ResultArea extends StatelessWidget {
  final String? result;
  final String? error;
  const _ResultArea({required this.result, required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError = error != null;
    final title = isError ? 'Please fix the following' : 'Predicted price';
    final text = error ?? result ?? 'Fill in all fields and tap Predict.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            text,
            style: result != null && !isError
                ? Theme.of(context).textTheme.headlineMedium
                : Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
