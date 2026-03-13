import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const CivicIssueApp());
}

const String kServerUrl = 'http://10.0.2.2:8080/report';

bool isValidServerUrl(String value) {
  try {
    final Uri uri = Uri.parse(value);
    return uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  } catch (_) {
    return false;
  }
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
      home: const FrontPageScreen(),
    );
  }
}

class IssueRecord {
  const IssueRecord({
    required this.issueType,
    required this.description,
    required this.timestamp,
    required this.location,
    required this.imageCount,
    required this.status,
  });

  final String issueType;
  final String description;
  final DateTime timestamp;
  final IssueLocation? location;
  final int imageCount;
  final String status;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'issueType': issueType,
      'description': description,
      'timestamp': timestamp.toIso8601String(),
      'location': location == null
          ? null
          : <String, dynamic>{
              'latitude': location!.latitude,
              'longitude': location!.longitude,
            },
      'imageCount': imageCount,
      'status': status,
    };
  }

  static IssueRecord fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? locationJson =
        json['location'] as Map<String, dynamic>?;
    return IssueRecord(
      issueType: json['issueType'] as String? ?? 'Unknown issue',
      description: json['description'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      location: locationJson == null
          ? null
          : IssueLocation(
              latitude: (locationJson['latitude'] as num?)?.toDouble() ?? 0,
              longitude: (locationJson['longitude'] as num?)?.toDouble() ?? 0,
            ),
      imageCount: (json['imageCount'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'saved_offline',
    );
  }
}

class StoredReport {
  const StoredReport({required this.record, required this.payloadJson});

  final IssueRecord record;
  final String payloadJson;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'record': record.toJson(),
      'payloadJson': payloadJson,
    };
  }

  static StoredReport fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> recordJson =
        json['record'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return StoredReport(
      record: IssueRecord.fromJson(recordJson),
      payloadJson: json['payloadJson'] as String? ?? '{}',
    );
  }
}

class ReportStore {
  Future<File> _file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(path.join(dir.path, 'stored_reports.json'));
  }

  Future<List<StoredReport>> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return <StoredReport>[];
      final String raw = await file.readAsString();
      final List<dynamic> data = jsonDecode(raw) as List<dynamic>;
      return data
          .whereType<Map<String, dynamic>>()
          .map(StoredReport.fromJson)
          .toList();
    } catch (_) {
      return <StoredReport>[];
    }
  }

  Future<void> save(List<StoredReport> reports) async {
    final File file = await _file();
    final String raw = jsonEncode(
      reports.map((StoredReport report) => report.toJson()).toList(),
    );
    await file.writeAsString(raw, flush: true);
  }
}

class FrontPageScreen extends StatefulWidget {
  const FrontPageScreen({super.key});

  @override
  State<FrontPageScreen> createState() => _FrontPageScreenState();
}

class _FrontPageScreenState extends State<FrontPageScreen> {
  final ReportStore _store = ReportStore();
  final List<StoredReport> _reports = <StoredReport>[];
  bool _isSyncing = false;
  static const Color _ink = Color(0xFF10223A);
  static const Color _accent = Color(0xFF1E6B6E);
  static const Color _cardTint = Color(0xFFF3F7F6);

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  Future<void> _loadReports() async {
    final List<StoredReport> loaded = await _store.load();
    loaded.sort(
      (StoredReport a, StoredReport b) =>
          b.record.timestamp.compareTo(a.record.timestamp),
    );
    if (!mounted) return;
    setState(() {
      _reports
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _openNewReport() async {
    final StoredReport? report =
        await Navigator.of(context).push<StoredReport>(
      MaterialPageRoute<StoredReport>(
        builder: (BuildContext context) => const ComplaintScreen(
          returnOnSuccess: true,
          showSuccessMessage: false,
        ),
      ),
    );

    if (report == null || !mounted) return;

    setState(() {
      _reports.insert(0, report);
    });
    await _store.save(_reports);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          report.record.status == 'saved_offline'
              ? 'Saved offline. Upload when internet is available.'
              : 'Issue report added to records.',
        ),
      ),
    );
  }

  int get _pendingCount =>
      _reports.where((StoredReport r) => r.record.status == 'saved_offline')
          .length;

  Future<void> _syncPendingReports() async {
    if (_isSyncing) return;
    if (!isValidServerUrl(kServerUrl)) {
      _showSnack('Invalid server URL: $kServerUrl');
      return;
    }
    setState(() {
      _isSyncing = true;
    });

    int success = 0;
    int failed = 0;

    for (final StoredReport report in _reports) {
      if (report.record.status != 'saved_offline') {
        continue;
      }
      try {
        final http.Response response = await http
            .post(
              Uri.parse(kServerUrl),
              headers: <String, String>{'Content-Type': 'application/json'},
              body: report.payloadJson,
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          success += 1;
          final IssueRecord updated = IssueRecord(
            issueType: report.record.issueType,
            description: report.record.description,
            timestamp: report.record.timestamp,
            location: report.record.location,
            imageCount: report.record.imageCount,
            status: 'submitted_to_authority',
          );
          final int index = _reports.indexOf(report);
          _reports[index] = StoredReport(
            record: updated,
            payloadJson: report.payloadJson,
          );
        } else {
          failed += 1;
        }
      } on TimeoutException {
        failed += 1;
      } on SocketException {
        failed += 1;
      } catch (_) {
        failed += 1;
      }
    }

    await _store.save(_reports);
    if (!mounted) return;
    setState(() {
      _isSyncing = false;
    });

    _showSnack(
      success > 0
          ? 'Uploaded $success report(s), failed $failed. Pending: $_pendingCount.'
          : 'No pending reports uploaded. Failed: $failed. Pending: $_pendingCount.',
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildRecordCard(IssueRecord record, int index) {
    final String formattedTime = DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(record.timestamp);
    final String locationText = record.location == null
        ? 'Location: not provided'
        : 'Location: ${record.location!.latitude.toStringAsFixed(5)}, '
            '${record.location!.longitude.toStringAsFixed(5)}';
    final Color stripeColor = Color.lerp(
      _accent,
      const Color(0xFFE76F51),
      (index % 3) / 3,
    )!;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: Colors.white,
          child: Row(
            children: <Widget>[
              Container(width: 6, color: stripeColor),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              record.issueType,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: _ink,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _cardTint,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              record.status.replaceAll('_', ' '),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        record.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _ink),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: <Widget>[
                          _InfoPill(
                            icon: Icons.schedule,
                            label: formattedTime,
                          ),
                          _InfoPill(
                            icon: Icons.photo,
                            label: '${record.imageCount} images',
                          ),
                          _InfoPill(
                            icon: Icons.place,
                            label: locationText,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFFE6F4F1), Color(0xFFF8F3E7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                height: 46,
                width: 46,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.hub, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Welcome to Civic Issue Report',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Report local issues with photos, location, and details. '
            'Your recent reports appear below.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _ink.withValues(alpha: 0.75),
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              InkWell(
                onTap: _openNewReport,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.add_circle, size: 18, color: _accent),
                      const SizedBox(width: 8),
                      Text(
                        'Tap + to add a new issue',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _ink,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_pendingCount > 0)
                FilledButton.icon(
                  onPressed: _isSyncing ? null : _syncPendingReports,
                  icon: _isSyncing
                      ? const SizedBox(
                          height: 14,
                          width: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload),
                  label: Text('Upload pending ($_pendingCount)'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: _StatCard(
            label: 'Total Reports',
            value: _reports.length.toString(),
            icon: Icons.assignment,
            tint: const Color(0xFF1976D2),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Last Activity',
            value: _reports.isEmpty
                ? 'No reports'
                : DateFormat('dd MMM').format(_reports.first.record.timestamp),
            icon: Icons.access_time,
            tint: const Color(0xFF388E3C),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Civic Issue Reporter'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNewReport,
        icon: const Icon(Icons.add),
        label: const Text('New Report'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFFF8FBFA), Color(0xFFFDF6EE)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildHeader(),
                const SizedBox(height: 16),
                _buildStatsRow(),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    const Icon(Icons.history, size: 18, color: _ink),
                    const SizedBox(width: 8),
                    const Text(
                      'Previous Records',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_reports.length} total',
                      style: TextStyle(
                        color: _ink.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_reports.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: Colors.white,
                      border: Border.all(
                        color: _accent.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          height: 42,
                          width: 42,
                          decoration: BoxDecoration(
                            color: _accent.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.inbox, color: _accent),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'No records yet. Submit your first issue report.',
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Column(
                    children: _reports
                        .asMap()
                        .entries
                        .map(
                          (MapEntry<int, StoredReport> entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildRecordCard(
                              entry.value.record,
                              entry.key,
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.tint,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            height: 40,
            width: 40,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: Colors.black54),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.black87),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class ComplaintScreen extends StatefulWidget {
  const ComplaintScreen({
    super.key,
    this.returnOnSuccess = false,
    this.showSuccessMessage = true,
  });

  final bool returnOnSuccess;
  final bool showSuccessMessage;

  @override
  State<ComplaintScreen> createState() => _ComplaintScreenState();
}

class IssueLocation {
  const IssueLocation({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  static const int _maxImages = 4;
  static const int _maxImageBytes = 1024 * 1024;
  static const Color _ink = Color(0xFF10223A);
  static const Color _accent = Color(0xFF1E6B6E);
  static const Color _cardTint = Color(0xFFF3F7F6);
  final TextEditingController _descriptionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  final List<String> _issueTypes = <String>[
    'Street light malfunction',
    'Broken road',
    'Water leakage',
    'Garbage overflow',
    'Drainage blockage',
    'Other civic issue',
  ];

  final List<XFile> _selectedImages = <XFile>[];
  String _selectedIssue = 'Street light malfunction';
  IssueLocation? _selectedLocation;
  DateTime? _capturedAt;
  bool _isSubmitting = false;
  String? _lastSentJson;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  // Image handling
  Future<void> _pickImage(ImageSource source) async {
    try {
      if (_selectedImages.length >= _maxImages) {
        _showMessage('You can attach up to $_maxImages images only.');
        return;
      }

      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 100,
      );
      if (image == null) return;

      final XFile? compressed = await _compressToLimit(image);
      if (compressed == null) {
        _showMessage('Could not compress image to 1 MB.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _selectedImages.add(compressed);
        _capturedAt = DateTime.now();
      });

      await _captureLocation();
    } catch (error) {
      _showMessage('Image capture failed: $error');
    }
  }

  Future<void> _pickMultipleFromGallery() async {
    try {
      if (_selectedImages.length >= _maxImages) {
        _showMessage('You can attach up to $_maxImages images only.');
        return;
      }

      final List<XFile> images = await _picker.pickMultiImage(
        imageQuality: 100,
      );
      if (images.isEmpty) return;

      final int availableSlots = _maxImages - _selectedImages.length;
      final List<XFile> toProcess = images.take(availableSlots).toList();

      int failed = 0;
      final List<XFile> compressedImages = <XFile>[];
      for (final XFile image in toProcess) {
        final XFile? compressed = await _compressToLimit(image);
        if (compressed == null) {
          failed += 1;
        } else {
          compressedImages.add(compressed);
        }
      }

      if (!mounted) return;
      setState(() {
        _selectedImages.addAll(compressedImages);
        if (compressedImages.isNotEmpty) {
          _capturedAt = DateTime.now();
        }
      });

      if (images.length > availableSlots) {
        _showMessage('Only $availableSlots images were added (limit $_maxImages).');
      } else if (failed > 0) {
        _showMessage('$failed image(s) could not be compressed to 1 MB.');
      }

      if (compressedImages.isNotEmpty) {
        await _captureLocation();
      }
    } catch (error) {
      _showMessage('Image selection failed: $error');
    }
  }

  Future<XFile?> _compressToLimit(XFile source) async {
    final bytes = await File(source.path).readAsBytes();
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    img.Image working = decoded;
    int quality = 90;
    List<int> encoded = img.encodeJpg(working, quality: quality);

    while (encoded.length > _maxImageBytes) {
      if (quality > 30) {
        quality -= 10;
      } else {
        final int newWidth = (working.width * 0.85).round();
        final int newHeight = (working.height * 0.85).round();
        if (newWidth < 320 || newHeight < 320) {
          break;
        }
        working = img.copyResize(working, width: newWidth, height: newHeight);
        quality = 80;
      }
      encoded = img.encodeJpg(working, quality: quality);
    }

    if (encoded.length > _maxImageBytes) {
      return null;
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String fileName =
        'issue_${DateTime.now().millisecondsSinceEpoch}_${source.name}.jpg';
    final String targetPath = path.join(tempDir.path, fileName);
    final File output = File(targetPath);
    await output.writeAsBytes(encoded, flush: true);
    return XFile(
      output.path,
      name: path.basename(output.path),
      mimeType: 'image/jpeg',
      length: encoded.length,
    );
  }

  void _removeImageAt(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      if (_selectedImages.isEmpty) {
        _capturedAt = null;
      }
    });
  }

  // Location handling
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
      _selectedLocation = IssueLocation(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    });
  }

  Future<void> _chooseLocationOnMap() async {
    final IssueLocation? pickedLocation = await Navigator.of(context)
        .push<IssueLocation>(
          MaterialPageRoute<IssueLocation>(
            builder: (BuildContext context) => MapLocationPickerScreen(
              initialLocation:
                  _selectedLocation ??
                  const IssueLocation(latitude: 12.9716, longitude: 77.5946),
            ),
          ),
        );

    if (pickedLocation == null || !mounted) {
      return;
    }

    setState(() {
      _selectedLocation = pickedLocation;
    });
  }

  // Payload + submission
  Future<Map<String, dynamic>> _buildPayload(String description) async {
    final DateTime reportTime = _capturedAt ?? DateTime.now();
    final List<Map<String, dynamic>> images = <Map<String, dynamic>>[];
    for (final XFile image in _selectedImages) {
      final List<int> imageBytes = await File(image.path).readAsBytes();
      images.add(<String, dynamic>{
        'fileName': image.name,
        'mimeType': 'image/jpeg',
        'sizeBytes': imageBytes.length,
        'base64Data': base64Encode(imageBytes),
      });
    }

    return <String, dynamic>{
      'issueType': _selectedIssue,
      'description': description,
      'timestamp': reportTime.toIso8601String(),
      'timestampDisplay': DateFormat('dd MMM yyyy, hh:mm a').format(reportTime),
      'location': _selectedLocation == null
          ? null
          : <String, dynamic>{
              'latitude': _selectedLocation!.latitude,
              'longitude': _selectedLocation!.longitude,
            },
      'images': images,
      'status': 'submitted_to_authority',
      'source': 'flutter_mobile_app',
    };
  }

  Future<void> _submitComplaint() async {
    final String trimmedDescription = _descriptionController.text.trim();

    if (_selectedImages.isEmpty) {
      _showMessage('Please upload at least one photo of the issue.');
      return;
    }

    if (trimmedDescription.isEmpty) {
      _showMessage('Please add a description of the problem.');
      return;
    }

    if (!isValidServerUrl(kServerUrl)) {
      _showMessage(
        'Invalid server URL. Example: http://192.168.1.10:8080/report',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    String? payloadJson;
    try {
      final Map<String, dynamic> payload = await _buildPayload(
        trimmedDescription,
      );
      payloadJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(payload);

      setState(() {
        _lastSentJson = payloadJson;
      });

      final http.Response response = await http
          .post(
            Uri.parse(kServerUrl),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: payloadJson,
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (widget.showSuccessMessage) {
          _showMessage('Complaint sent to authority server successfully.');
        }

        if (widget.returnOnSuccess && mounted) {
          Navigator.of(context).pop(
            StoredReport(
              record: IssueRecord(
                issueType: _selectedIssue,
                description: trimmedDescription,
                timestamp: _capturedAt ?? DateTime.now(),
                location: _selectedLocation,
                imageCount: _selectedImages.length,
                status: 'submitted_to_authority',
              ),
              payloadJson: payloadJson,
            ),
          );
        }
      } else {
        _showMessage(
          'Server rejected complaint (${response.statusCode}): ${response.body}',
        );
      }
    } on TimeoutException {
      if (payloadJson != null) {
        _saveOfflineAndReturn(payloadJson, trimmedDescription);
      }
      _showMessage(
        'No internet. Saved offline. Upload when you are online.',
      );
    } on SocketException {
      if (payloadJson != null) {
        _saveOfflineAndReturn(payloadJson, trimmedDescription);
      }
      _showMessage(
        'Network error. Saved offline. Upload when you are online.',
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

  void _saveOfflineAndReturn(String payloadJson, String description) {
    if (!widget.returnOnSuccess || !mounted) return;
    Navigator.of(context).pop(
      StoredReport(
        record: IssueRecord(
          issueType: _selectedIssue,
          description: description,
          timestamp: _capturedAt ?? DateTime.now(),
          location: _selectedLocation,
          imageCount: _selectedImages.length,
          status: 'saved_offline',
        ),
        payloadJson: payloadJson,
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _locationText {
    if (_selectedLocation == null) return 'Location not selected yet';
    return '${_selectedLocation!.latitude.toStringAsFixed(6)}, '
        '${_selectedLocation!.longitude.toStringAsFixed(6)}';
  }

  String get _timeText {
    final DateTime timestamp = _capturedAt ?? DateTime.now();
    return DateFormat('dd MMM yyyy, hh:mm a').format(timestamp);
  }

  String get _descriptionPreview {
    final String value = _descriptionController.text.trim();
    return value.isEmpty ? 'Not entered yet' : value;
  }

  Widget _buildImagePreview() {
    if (_selectedImages.isEmpty) {
      return Center(
        child: Text(
          'No image selected',
          style: TextStyle(color: _ink.withValues(alpha: 0.7)),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        itemCount: _selectedImages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (BuildContext context, int index) {
          final XFile image = _selectedImages[index];
          return Stack(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(image.path),
                  width: 160,
                  height: 160,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: InkWell(
                  onTap: () => _removeImageAt(index),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _pickImage(ImageSource.camera),
          icon: const Icon(Icons.camera_alt),
          label: const Text('Capture'),
          style: FilledButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.white,
          ),
        ),
        OutlinedButton.icon(
          onPressed: _pickMultipleFromGallery,
          icon: const Icon(Icons.photo_library),
          label: const Text('Choose from Gallery'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _captureLocation,
          icon: const Icon(Icons.location_searching),
          label: const Text('Refresh Location'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _chooseLocationOnMap,
          icon: const Icon(Icons.map),
          label: const Text('Choose on Map'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: BorderSide(color: _accent.withValues(alpha: 0.4)),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCard() {
    return _buildSectionCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Preview Before Sending',
              style: TextStyle(fontWeight: FontWeight.bold, color: _ink),
            ),
            const SizedBox(height: 8),
            Text('Issue: $_selectedIssue', style: const TextStyle(color: _ink)),
            const SizedBox(height: 6),
            Text('Timestamp: $_timeText', style: const TextStyle(color: _ink)),
            const SizedBox(height: 6),
            Text('Location: $_locationText', style: const TextStyle(color: _ink)),
            const SizedBox(height: 6),
            Text(
              'Description: $_descriptionPreview',
              style: const TextStyle(color: _ink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLastSentPayload() {
    if (_lastSentJson == null) return const SizedBox.shrink();
    return _buildSectionCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Last Sent JSON Payload',
              style: TextStyle(fontWeight: FontWeight.bold, color: _ink),
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
    );
  }

  Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFFE6F4F1), Color(0xFFF8F3E7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                height: 46,
                width: 46,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.edit_note, color: _accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Create a New Issue Report',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Add photos, choose a location, and describe the issue so the authority can act quickly.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _ink.withValues(alpha: 0.75),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.08)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Civic Issue Reporter'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFFF8FBFA), Color(0xFFFDF6EE)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _buildHeaderCard(),
                const SizedBox(height: 16),
                _buildSectionCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Issue Photos',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          height: 220,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: _cardTint,
                            border: Border.all(
                              color: _accent.withValues(alpha: 0.2),
                            ),
                          ),
                          child: _buildImagePreview(),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Selected ${_selectedImages.length}/$_maxImages images',
                          style: TextStyle(
                            color: _ink.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildActionButtons(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildSectionCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Issue Details',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _ink,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedIssue,
                          decoration: InputDecoration(
                            labelText: 'Issue Category',
                            filled: true,
                            fillColor: Colors.white,
                            labelStyle: const TextStyle(color: _ink),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.3),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.25),
                              ),
                            ),
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
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Problem Description',
                            hintText: 'Describe the issue in detail...',
                            filled: true,
                            fillColor: Colors.white,
                            labelStyle: const TextStyle(color: _ink),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.3),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _accent.withValues(alpha: 0.25),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildPreviewCard(),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isSubmitting ? null : _submitComplaint,
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
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
                  _buildLastSentPayload(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MapLocationPickerScreen extends StatefulWidget {
  const MapLocationPickerScreen({super.key, required this.initialLocation});

  final IssueLocation initialLocation;

  @override
  State<MapLocationPickerScreen> createState() =>
      _MapLocationPickerScreenState();
}

class _MapLocationPickerScreenState extends State<MapLocationPickerScreen> {
  static final List<_RecentPlace> _recentPlaces = <_RecentPlace>[];
  late final MapController _mapController;
  late LatLng _pickedPoint;
  LatLng? _currentLocation;
  bool _hasUserMoved = false;
  bool _isSearching = false;
  String _pickedLabel = 'Pinned location';
  final TextEditingController _searchController = TextEditingController();
  final List<_PlaceSearchResult> _searchResults = <_PlaceSearchResult>[];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _pickedPoint = LatLng(
      widget.initialLocation.latitude,
      widget.initialLocation.longitude,
    );
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    setState(() {
      _hasUserMoved = true;
      _pickedPoint = point;
      _pickedLabel = 'Pinned location';
    });
  }

  void _confirmSelection() {
    _addRecentPlace(_pickedLabel, _pickedPoint);
    Navigator.of(context).pop(
      IssueLocation(
        latitude: _pickedPoint.latitude,
        longitude: _pickedPoint.longitude,
      ),
    );
  }

  Future<void> _loadCurrentLocation() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled || !mounted) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    if (!mounted) return;

    final LatLng location = LatLng(position.latitude, position.longitude);
    setState(() {
      _currentLocation = location;
      if (!_hasUserMoved) {
        _pickedPoint = location;
        _pickedLabel = 'Current location';
      }
    });

    if (!_hasUserMoved) {
      _mapController.move(location, 16);
    }
  }

  Future<void> _searchPlaces(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      final Uri uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&limit=5&addressdetails=1&q=${Uri.encodeQueryComponent(trimmed)}',
      );
      final http.Response response = await http.get(
        uri,
        headers: <String, String>{
          'User-Agent': 'civic_issue_management/0.1.0',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        _showSnack('Search failed (${response.statusCode}).');
        return;
      }

      final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
      final List<_PlaceSearchResult> results = data
          .map((dynamic raw) => _PlaceSearchResult.fromJson(raw))
          .where((result) => result != null)
          .cast<_PlaceSearchResult>()
          .toList();

      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(results);
      });
    } catch (error) {
      if (!mounted) return;
      _showSnack('Search error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _selectSearchResult(_PlaceSearchResult result) {
    setState(() {
      _pickedPoint = result.point;
      _pickedLabel = result.label;
      _hasUserMoved = true;
      _searchResults.clear();
      _searchController.text = result.label;
    });
    _mapController.move(result.point, 16);
  }

  void _addRecentPlace(String label, LatLng point) {
    _recentPlaces.removeWhere((place) => place.label == label);
    _recentPlaces.insert(0, _RecentPlace(label: label, point: point));
    if (_recentPlaces.length > 5) {
      _recentPlaces.removeRange(5, _recentPlaces.length);
    }
  }

  void _useRecentPlace(_RecentPlace place) {
    setState(() {
      _pickedPoint = place.point;
      _pickedLabel = place.label;
      _hasUserMoved = true;
    });
    _mapController.move(place.point, 16);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Issue Location'),
        actions: <Widget>[
          TextButton(
            onPressed: _confirmSelection,
            child: const Text('Use This'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchPlaces,
                  decoration: InputDecoration(
                    labelText: 'Search a place',
                    hintText: 'Area, landmark, address',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchResults.clear();
                              });
                            },
                          ),
                  ),
                ),
                if (_searchResults.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Card(
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _searchResults.length,
                      itemBuilder: (BuildContext context, int index) {
                        final _PlaceSearchResult result = _searchResults[index];
                        return ListTile(
                          title: Text(result.label),
                          onTap: () => _selectSearchResult(result),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _currentLocation == null
                          ? _loadCurrentLocation
                          : () {
                              setState(() {
                                _pickedPoint = _currentLocation!;
                                _pickedLabel = 'Current location';
                                _hasUserMoved = true;
                              });
                              _mapController.move(_currentLocation!, 16);
                            },
                      icon: const Icon(Icons.my_location),
                      label: const Text('Use Current'),
                    ),
                    const SizedBox(width: 12),
                    if (_recentPlaces.isNotEmpty)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Wrap(
                            spacing: 8,
                            children: _recentPlaces
                                .map(
                                  (_RecentPlace place) => ActionChip(
                                    label: Text(place.label),
                                    onPressed: () => _useRecentPlace(place),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _pickedPoint,
                initialZoom: 16,
                onTap: _onMapTap,
              ),
              children: <Widget>[
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.civic_issue_management',
                ),
                MarkerLayer(
                  markers: <Marker>[
                    if (_currentLocation != null)
                      Marker(
                        point: _currentLocation!,
                        width: 24,
                        height: 24,
                        child: const Icon(
                          Icons.radio_button_checked,
                          color: Colors.blue,
                          size: 20,
                        ),
                      ),
                    Marker(
                      point: _pickedPoint,
                      width: 44,
                      height: 44,
                      child: const Icon(
                        Icons.location_pin,
                        size: 44,
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Selected: ${_pickedPoint.latitude.toStringAsFixed(6)}, ${_pickedPoint.longitude.toStringAsFixed(6)}',
                  ),
                ),
                FilledButton(
                  onPressed: _confirmSelection,
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceSearchResult {
  const _PlaceSearchResult({required this.label, required this.point});

  final String label;
  final LatLng point;

  static _PlaceSearchResult? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final String? displayName = raw['display_name'] as String?;
    final String? latRaw = raw['lat'] as String?;
    final String? lonRaw = raw['lon'] as String?;
    if (displayName == null || latRaw == null || lonRaw == null) {
      return null;
    }
    final double? lat = double.tryParse(latRaw);
    final double? lon = double.tryParse(lonRaw);
    if (lat == null || lon == null) return null;
    return _PlaceSearchResult(label: displayName, point: LatLng(lat, lon));
  }
}

class _RecentPlace {
  const _RecentPlace({required this.label, required this.point});

  final String label;
  final LatLng point;
}
