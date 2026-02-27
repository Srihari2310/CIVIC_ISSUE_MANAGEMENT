import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const CivicIssueApp());
}

class CivicIssueApp extends StatelessWidget {
  const CivicIssueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Civic Issue Reporting',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ComplaintScreen(),
    );
  }
}

class ComplaintScreen extends StatefulWidget {
  const ComplaintScreen({super.key});

  @override
  State<ComplaintScreen> createState() => _ComplaintScreenState();
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _serverUrlController = TextEditingController(
    text: 'http://10.0.2.2:8080/report',
  );
  final ImagePicker _picker = ImagePicker();

  final List<String> _issueTypes = <String>[
    'Street light malfunction',
    'Broken road',
    'Water leakage',
    'Garbage overflow',
    'Drainage blockage',
    'Other civic issue',
  ];

  XFile? _selectedImage;
  String _selectedIssue = 'Street light malfunction';
  Position? _position;
  DateTime? _capturedAt;
  bool _isSubmitting = false;
  String? _lastSentJson;

  @override
  void initState() {
    super.initState();
    _serverUrlController.addListener(_onServerUrlChanged);
  }

  void _onServerUrlChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _serverUrlController.removeListener(_onServerUrlChanged);
    _descriptionController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (image == null) {
        return;
      }

      setState(() {
        _selectedImage = image;
        _capturedAt = DateTime.now();
      });

      await _captureLocation();
    } catch (error) {
      _showMessage('Image capture failed: $error');
    }
  }

  Future<void> _captureLocation() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _showMessage('Location services are turned off.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('Location permission is required to attach issue location.');
      return;
    }

    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );

    if (!mounted) return;
    setState(() {
      _position = position;
    });
  }

  Future<Map<String, dynamic>> _buildPayload(String description) async {
    final DateTime reportTime = _capturedAt ?? DateTime.now();
    final List<int> imageBytes = await File(_selectedImage!.path).readAsBytes();

    return <String, dynamic>{
      'issueType': _selectedIssue,
      'description': description,
      'timestamp': reportTime.toIso8601String(),
      'timestampDisplay': DateFormat('dd MMM yyyy, hh:mm a').format(reportTime),
      'location': _position == null
          ? null
          : <String, dynamic>{
              'latitude': _position!.latitude,
              'longitude': _position!.longitude,
            },
      'image': <String, dynamic>{
        'fileName': _selectedImage!.name,
        'mimeType': 'image/jpeg',
        'base64Data': base64Encode(imageBytes),
      },
      'status': 'submitted_to_authority',
      'source': 'flutter_mobile_app',
    };
  }

  String _healthUrlFromReportUrl(String reportUrl) {
    final Uri uri = Uri.parse(reportUrl);
    return uri.replace(path: '/health', query: '').toString();
  }

  String _dashboardUrlFromReportUrl(String reportUrl) {
    final Uri uri = Uri.parse(reportUrl);
    return uri.replace(path: '/', query: '').toString();
  }

  bool _isValidServerUrl(String value) {
    try {
      final Uri uri = Uri.parse(value);
      return uri.hasScheme &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _testServerConnection() async {
    final String reportUrl = _serverUrlController.text.trim();
    if (!_isValidServerUrl(reportUrl)) {
      _showMessage(
        'Invalid server URL. Example: http://192.168.1.10:8080/report',
      );
      return;
    }

    final String healthUrl = _healthUrlFromReportUrl(reportUrl);

    try {
      final http.Response response = await http
          .get(Uri.parse(healthUrl))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        _showMessage('Server reachable: $healthUrl');
      } else {
        _showMessage(
          'Server reachable but unhealthy (${response.statusCode}).',
        );
      }
    } on TimeoutException {
      _showMessage(
        'Connection timed out. Check server running, IP, Wi-Fi, and firewall port 8080.',
      );
    } on SocketException {
      _showMessage(
        'Network error. Use desktop LAN IP (not localhost/10.0.2.2 on real phone).',
      );
    } catch (error) {
      _showMessage('Connection test failed: $error');
    }
  }

  Future<void> _submitComplaint() async {
    final String trimmedDescription = _descriptionController.text.trim();

    if (_selectedImage == null) {
      _showMessage('Please upload a photo of the issue.');
      return;
    }

    if (trimmedDescription.isEmpty) {
      _showMessage('Please add a description of the problem.');
      return;
    }

    final String serverUrl = _serverUrlController.text.trim();
    if (serverUrl.isEmpty) {
      _showMessage('Please enter the desktop server URL.');
      return;
    }
    if (!_isValidServerUrl(serverUrl)) {
      _showMessage(
        'Invalid server URL. Example: http://192.168.1.10:8080/report',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final Map<String, dynamic> payload = await _buildPayload(
        trimmedDescription,
      );
      final String payloadJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(payload);

      setState(() {
        _lastSentJson = payloadJson;
      });

      final http.Response response = await http
          .post(
            Uri.parse(serverUrl),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: payloadJson,
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _showMessage('Complaint sent to authority server successfully.');
      } else {
        _showMessage(
          'Server rejected complaint (${response.statusCode}): ${response.body}',
        );
      }
    } on TimeoutException {
      _showMessage(
        'Request timed out. Verify server URL, server status, Wi-Fi network, and firewall.',
      );
    } on SocketException {
      _showMessage(
        'Network error while sending. On real phone use http://<desktop-ip>:8080/report.',
      );
    } on FormatException {
      _showMessage('Invalid URL format. Please check desktop server URL.');
    } on http.ClientException catch (clientError) {
      _showMessage('HTTP client error: $clientError');
    } catch (error) {
      _showMessage('Failed to send complaint: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _locationText {
    if (_position == null) return 'Location not captured yet';
    return '${_position!.latitude.toStringAsFixed(6)}, '
        '${_position!.longitude.toStringAsFixed(6)}';
  }

  String get _timeText {
    final DateTime timestamp = _capturedAt ?? DateTime.now();
    return DateFormat('dd MMM yyyy, hh:mm a').format(timestamp);
  }

  String get _descriptionPreview {
    final String value = _descriptionController.text.trim();
    return value.isEmpty ? 'Not entered yet' : value;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Civic Issue Reporter')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Capture civic issue details, review preview, then send JSON to desktop authority server.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              Container(
                height: 220,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: _selectedImage == null
                    ? const Center(child: Text('No image selected'))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(_selectedImage!.path),
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Capture'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Choose from Gallery'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _captureLocation,
                    icon: const Icon(Icons.location_searching),
                    label: const Text('Refresh Location'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  labelText: 'Desktop Server URL',
                  hintText: 'http://<desktop-ip>:8080/report',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Open dashboard in desktop browser: '
                '${_isValidServerUrl(_serverUrlController.text.trim()) ? _dashboardUrlFromReportUrl(_serverUrlController.text.trim()) : 'http://<desktop-ip>:8080/'}',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _testServerConnection,
                  icon: const Icon(Icons.network_check),
                  label: const Text('Test Server Connection'),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedIssue,
                decoration: const InputDecoration(
                  labelText: 'Issue Category',
                  border: OutlineInputBorder(),
                ),
                items: _issueTypes
                    .map(
                      (String issue) => DropdownMenuItem<String>(
                        value: issue,
                        child: Text(issue),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value == null) return;
                  setState(() {
                    _selectedIssue = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Problem Description',
                  hintText: 'Describe the issue in detail...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Preview Before Sending',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text('Issue: $_selectedIssue'),
                      const SizedBox(height: 6),
                      Text('Timestamp: $_timeText'),
                      const SizedBox(height: 6),
                      Text('Location: $_locationText'),
                      const SizedBox(height: 6),
                      Text('Description: $_descriptionPreview'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isSubmitting ? null : _submitComplaint,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send Complaint JSON to Authority'),
                ),
              ),
              if (_lastSentJson != null) ...<Widget>[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Last Sent JSON Payload',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectableText(
                            _lastSentJson!,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
