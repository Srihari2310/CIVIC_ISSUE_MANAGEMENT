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

class IssueLocation {
  const IssueLocation({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class _ComplaintScreenState extends State<ComplaintScreen> {
  static const String _serverUrl = 'http://10.0.2.2:8080/report';
  static const int _maxImages = 4;
  static const int _maxImageBytes = 1024 * 1024;
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

    if (!_isValidServerUrl(_serverUrl)) {
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
            Uri.parse(_serverUrl),
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
      return const Center(child: Text('No image selected'));
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
        ),
        OutlinedButton.icon(
          onPressed: _pickMultipleFromGallery,
          icon: const Icon(Icons.photo_library),
          label: const Text('Choose from Gallery'),
        ),
        OutlinedButton.icon(
          onPressed: _captureLocation,
          icon: const Icon(Icons.location_searching),
          label: const Text('Refresh Location'),
        ),
        OutlinedButton.icon(
          onPressed: _chooseLocationOnMap,
          icon: const Icon(Icons.map),
          label: const Text('Choose on Map'),
        ),
      ],
    );
  }

  Widget _buildPreviewCard() {
    return Card(
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
    );
  }

  Widget _buildLastSentPayload() {
    if (_lastSentJson == null) return const SizedBox.shrink();
    return Card(
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
    );
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
                child: _buildImagePreview(),
              ),
              const SizedBox(height: 12),
              Text('Selected ${_selectedImages.length}/$_maxImages images'),
              const SizedBox(height: 8),
              _buildActionButtons(),
              const SizedBox(height: 20),
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
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Problem Description',
                  hintText: 'Describe the issue in detail...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _buildPreviewCard(),
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
                _buildLastSentPayload(),
              ],
            ],
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
